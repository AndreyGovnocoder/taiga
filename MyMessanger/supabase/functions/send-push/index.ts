// Импортируем стандартный HTTP-сервер Deno
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
// Используем нативный префикс npm: вместо esm.sh (работает быстрее и надежнее)
import { createClient } from "npm:@supabase/supabase-js@2.39.3";
import { SignJWT, importPKCS8 } from "npm:jose@5.2.2";

// Описываем структуру данных, которая будет прилетать из базы данных (Webhook)
interface WebhookPayload {
  type: 'INSERT';
  table: 'messages';
  record: {
    id: string;
    chat_id: string;
    sender_id: string;
    content_type: string;
    content_text: string | null;
  };
}

serve(async (req) => {
  try {
    // 1. Получаем данные из запроса (Webhook от базы данных)
    const payload: WebhookPayload = await req.json();
    const record = payload.record;

    // Если это не новое сообщение, игнорируем
    if (payload.type !== 'INSERT' || payload.table !== 'messages') {
      return new Response("Not a new message", { status: 200 });
    }

    // 2. Инициализируем клиента Supabase с полными правами (Service Role)
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // 3. Получаем имя отправителя
    const { data: senderData, error: senderError } = await supabase
      .from('users')
      .select('name')
      .eq('id', record.sender_id)
      .single();

    if (senderError || !senderData) {
      console.error("Не удалось найти отправителя:", senderError);
      return new Response("Sender not found", { status: 400 });
    }

    const senderName = senderData.name;

    // 4. Формируем текст уведомления
    let pushText = record.content_text || "Новое сообщение";
    if (record.content_type === 'image') {
      pushText = record.content_text ? `📷 ${record.content_text}` : "📷 Изображение";
    }

    // 5. Ищем получателей: участников чата (кроме отправителя), у которых есть apns_token
    const { data: participants, error: participantsError } = await supabase
      .from('chat_participants')
      .select(`
        unread_count,
        users!inner (
          id,
          apns_token
        )
      `)
      .eq('chat_id', record.chat_id)
      .neq('user_id', record.sender_id)
      .not('users.apns_token', 'is', null);

    if (participantsError || !participants || participants.length === 0) {
      console.log("Нет получателей с валидными токенами. Пуш не отправлен.");
      return new Response("No target devices", { status: 200 });
    }

    // 6. Подготавливаем ключи Apple
    const teamId = Deno.env.get("APNS_TEAM_ID")!;
    const keyId = Deno.env.get("APNS_KEY_ID")!;
    const privateKey = Deno.env.get("APNS_PRIVATE_KEY")!;
    const bundleId = Deno.env.get("APNS_BUNDLE_ID") || "com.guliy.MyMessanger";
    
    const isSandbox = Deno.env.get("APNS_SANDBOX") !== "false";
    const apnsHost = isSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";

    // 7. Генерируем временный зашифрованный JWT токен для авторизации на серверах Apple
    const ecPrivateKey = await importPKCS8(privateKey, 'ES256');
    const jwt = await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: keyId })
      .setIssuer(teamId)
      .setIssuedAt()
      .sign(ecPrivateKey);

    // 8. Отправляем пуши каждому получателю
    const pushPromises = participants.map(async (p: any) => {
      const apnsToken = p.users.apns_token;
      const unreadCount = p.unread_count;

      // Формируем payload для iOS 18 с фоновым пробуждением
      const applePayload = {
        aps: {
          alert: {
            title: senderName,
            body: pushText
          },
          sound: "default",
          badge: unreadCount,
          "content-available": 1, // ВАЖНО: Будит iOS приложение в фоне!
          "mutable-content": 1    // ВАЖНО: Позволяет перехватить пуш (например, для фото)
        },
        // Скрытые данные передаются прямо в приложение для обработки
        chat_id: record.chat_id,
        message_id: record.id
      };

      // Делаем HTTP/2 запрос к серверам Apple
      const response = await fetch(`https://${apnsHost}/3/device/${apnsToken}`, {
        method: 'POST',
        headers: {
          'authorization': `bearer ${jwt}`,
          'apns-topic': bundleId,
          'apns-push-type': 'alert',
          'apns-priority': '10' // 10 = доставить немедленно
        },
        body: JSON.stringify(applePayload)
      });

      if (!response.ok) {
        const errorText = await response.text();
        console.error(`Ошибка отправки пуша на токен ${apnsToken}:`, response.status, errorText);
        
        // Очистка недействительного токена
        if (response.status === 410) {
           await supabase.from('users').update({ apns_token: null }).eq('id', p.users.id);
           console.log(`Токен ${apnsToken} удален из базы (410 Unregistered).`);
        }
      } else {
        console.log(`Успешно отправлено на токен: ${apnsToken}`);
      }
    });

    // Ждем выполнения всех запросов
    await Promise.all(pushPromises);

    return new Response("Pushes sent successfully", { status: 200 });

  } catch (error: any) {
    console.error("Критическая ошибка функции:", error);
    return new Response(`Error: ${error.message}`, { status: 500 });
  }
});
