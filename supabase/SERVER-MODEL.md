# Серверная модель Supabase (проверено инспекцией БД)

> Снимок фактического состояния backend проекта `rhoyopwzdqtcyawiipya`, полученный read-only запросами к системным каталогам (Management API). Цель — версионный контроль серверной модели (миграции в репозиторий не коммитились). Секреты (service_role JWT) обезличены.

## Таблицы (public) и колонки

- **users**: `id`(uuid, =auth.uid), `phone_number`(text?), `name`(text), `nickname`(text?), `avatar_url`(text?, тумба), `avatar_url_full`(text?, полный аватар — профиль/fullscreen; см. `security/chat-clear-delete-and-avatar-full.sql`), `is_online`(bool, def false), `apns_token`(text?), `created_at`.
- **chats**: `id`(uuid, gen_random_uuid), `type`(text), `name`(text?), `avatar_url`(text?), `created_at`, `last_message_id`(uuid?), `last_message_text`, `last_message_at`, `last_message_sender_id`, `last_message_type`(def 'text') — денормализованный snapshot.
- **chat_participants**: `chat_id`, `user_id`, `unread_count`(int, def 0), `role`(text, def 'member'), `is_muted`(bool, def false), `cleared_at`(timestamptz?, метка «очистить чат»), `deleted_at`(timestamptz?, метка «удалить чат»). См. `security/chat-clear-delete-and-avatar-full.sql`.
- **messages**: `id`, `chat_id`, `sender_id`, `content_type`, `content_text?`, `content_image_url?`, `content_thumb_url?`, `content_blur_hash?`, `image_width/height`(numeric?), `status`(def 'sent'), `reply_to_message_id?`, `thread_root_id?`, `expires_at?`(TTL), `created_at`.
- **message_events**: `id`, `chat_id`, `message_id`, `event_type`, `new_text?`, `actor_id`, `created_at`.

## 🔴 Безопасность — критично (исходное состояние при инспекции)

> **СТАТУС: ИСПРАВЛЕНО.** Миграция `supabase/security/enable-rls.sql` применена к проекту и проверена live: RLS включён на всех 5 таблицах, 12 политик на месте, прямой доступ роли `anon` к таблицам отозван (anon-запрос к `users` → `401 permission denied`). Synthetic smoke-тест под `authenticated` подтвердил: self-доступ работает, чужие профили/сообщения не видны, `delete_user_account` отрабатывает. ⚠️ Полные чат/группа/медиа-флоу нужно проверить на Mac на реальных аккаунтах с общим чатом — там задействованы `is_chat_participant`/`shares_chat_with`, которые smoke-тест (без чатов) не покрыл.

- **RLS ВЫКЛЮЧЕН на всех 5 таблицах** (`rls_enabled=false`), политик нет.
- **Гранты:** роли `anon` И `authenticated` имеют `SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER` на всех таблицах.
- Следствие: публичный (anon) ключ из .ipa даёт полный доступ к чтению/изменению/удалению всех данных всех пользователей. Подтверждено: `GET /rest/v1/users?select=id` с anon-ключом → HTTP 200 + строка.
- **Исправление:** `supabase/security/enable-rls.sql` (требует применения и теста на Mac).

## Storage

- Бакеты `avatars` и `chat_media` — оба `public = true`.
- Политики `storage.objects`:
  - `avatars`: «Allow all operations» для роли `public` (ALL).
  - `chat_media`: «Allow public read» (SELECT) + «Allow public uploads» (INSERT) для `public`.
- Следствие: чужие медиа читаются/заливаются без авторизации. Рекомендация — приватный бакет + signed URL (правки и в приложении).

## RPC-функции (public, все SECURITY DEFINER)

- `check_phone_exists(p_phone)` / `check_nickname_exists(p_nickname)` → bool (пред-авторизационные).
- `get_or_create_personal_chat(p_target_user_id)` → uuid (идемпотентно по двум участникам).
- `create_group_chat(p_name, p_avatar_url, p_participant_ids[])` → uuid; создатель = admin; лимит 50.
- `add_group_participant(p_chat_id, p_user_id)` — проверяет, что вызывающий admin; лимит 50; запрет дублей.
- `remove_group_participant(p_chat_id, p_user_id)` — самовыход ИЛИ admin удаляет другого.
- `delete_user_account()` — `DELETE public.users WHERE id=auth.uid()` + `DELETE auth.users WHERE id=auth.uid()`. Полагается на каскад FK для сообщений/чатов. **НЕ удаляет файлы Storage** (пробел для Apple 5.1.1(v)).
- `get_registered_contacts(phone_numbers[])` → `SETOF users` через `SELECT *` (возвращает и `apns_token` — лишнее раскрытие; добавить выбор колонок + лимит/rate-limit).
- `clear_chat(p_chat_id)` / `delete_chat(p_chat_id)` / `undelete_chat(p_chat_id)` — персистентные per-user метки очистки/удаления чата на `chat_participants` (SECURITY DEFINER, `WHERE user_id=auth.uid()`; clear→cleared_at+unread=0, delete→+deleted_at, undelete→deleted_at=NULL). См. `security/chat-clear-delete-and-avatar-full.sql`.

## Триггеры (public, на messages)

- `before_message_insert_set_thread` (BEFORE INSERT) → `set_thread_root_id()` — проставляет `thread_root_id`, помечает корень ветки.
- `before_message_set_expires` (BEFORE INSERT) → `set_message_expires_at()` — `expires_at = created_at + 3 дня` (TTL; механизм фактического удаления просроченных в инспекции не виден — вероятно внешний job/pg_cron, проверить).
- `on_message_created` (AFTER INSERT) → `handle_new_message()` — snapshot чата + инкремент unread (кроме отправителя, если не muted).
- `on_message_deleted` (BEFORE DELETE) → `handle_message_deleted()` — декремент unread + пересчёт snapshot.
- `Push On New Message` (AFTER INSERT) → `supabase_functions.http_request('https://rhoyopwzdqtcyawiipya.supabase.co/functions/v1/send-push', 'POST', {Authorization: Bearer <SERVICE_ROLE_JWT — ОБЕЗЛИЧЕНО>}, ...)`. ⚠️ В реальном DDL зашит долгоживущий (exp ~2036) service_role JWT — рекомендуется ротация.
- `handle_new_user()` — триггер на `auth.users` INSERT (вне public): создаёт `public.users` из `raw_user_meta_data` (name/nickname/phone_number).
- `rls_auto_enable()` — event trigger, авто-включает RLS на новых таблицах public. Существующие таблицы он не покрыл (созданы раньше / не сработал) — поэтому RLS на них off.
