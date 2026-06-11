import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2.39.3";
import { SignJWT, importPKCS8 } from "npm:jose@5.2.2";

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
    const payload: WebhookPayload = await req.json();
    const record = payload.record;

    if (payload.type !== 'INSERT' || payload.table !== 'messages') {
      return new Response("Not a new message", { status: 200 });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Имя отправителя
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

    // Текст уведомления
    let pushText = record.content_text || "Новое сообщение";
    if (record.content_type === 'image') {
      pushText = record.content_text ? `📷 ${record.content_text}` : "📷 Изображение";
    }

    // Получатели: участники чата (кроме отправителя) с apns_token
    const { data: participants, error: participantsError } = await supabase
      .from('chat_participants')
      .select(`
        user_id,
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

    // Apple Push keys
    const teamId = Deno.env.get("APNS_TEAM_ID")!;
    const keyId = Deno.env.get("APNS_KEY_ID")!;
    const privateKey = Deno.env.get("APNS_PRIVATE_KEY")!;
    const bundleId = Deno.env.get("APNS_BUNDLE_ID") || "com.guliy.MyMessanger";
    
    const isSandbox = Deno.env.get("APNS_SANDBOX") !== "false";
    const apnsHost = isSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";

    const ecPrivateKey = await importPKCS8(privateKey, 'ES256');
    const jwt = await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: keyId })
      .setIssuer(teamId)
      .setIssuedAt()
      .sign(ecPrivateKey);

    // Отправляем пуши каждому получателю
    const pushPromises = participants.map(async (p: any) => {
      const apnsToken = p.users.apns_token;
      const userId = p.user_id;

      // Считаем ОБЩЕЕ количество непрочитанных по ВСЕМ чатам пользователя
      const { data: allChats, error: allChatsError } = await supabase
        .from('chat_participants')
        .select('unread_count')
        .eq('user_id', userId);

      let totalBadge = 0;
      if (!allChatsError && allChats) {
        totalBadge = allChats.reduce((sum: number, c: any) => sum + (c.unread_count || 0), 0);
      }

      const applePayload = {
        aps: {
          alert: {
            title: senderName,
            body: pushText
          },
          sound: "default",
          badge: totalBadge,
          "content-available": 1,
          "mutable-content": 1
        },
        chat_id: record.chat_id,
        message_id: record.id
      };

      const response = await fetch(`https://${apnsHost}/3/device/${apnsToken}`, {
        method: 'POST',
        headers: {
          'authorization': `bearer ${jwt}`,
          'apns-topic': bundleId,
          'apns-push-type': 'alert',
          'apns-priority': '10'
        },
        body: JSON.stringify(applePayload)
      });

      if (!response.ok) {
        const errorText = await response.text();
        console.error(`Ошибка отправки пуша на токен ${apnsToken}:`, response.status, errorText);
        
        if (response.status === 410) {
           await supabase.from('users').update({ apns_token: null }).eq('id', p.users.id);
           console.log(`Токен ${apnsToken} удален из базы (410 Unregistered).`);
        }
      } else {
        console.log(`Пуш отправлен: badge=${totalBadge}, token=${apnsToken}`);
      }
    });

    await Promise.all(pushPromises);

    return new Response("Pushes sent successfully", { status: 200 });

  } catch (error: any) {
    console.error("Критическая ошибка функции:", error);
    return new Response(`Error: ${error.message}`, { status: 500 });
  }
});
