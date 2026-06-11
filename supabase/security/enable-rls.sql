-- =====================================================================
-- ИСПРАВЛЕНИЕ КРИТИЧЕСКОЙ УЯЗВИМОСТИ: включение RLS + политики доступа.
--
-- ПРОБЛЕМА (проверено инспекцией БД):
--   RLS выключен на ВСЕХ таблицах, а роли anon/authenticated имеют полные
--   права (SELECT/INSERT/UPDATE/DELETE/TRUNCATE). Публичный (anon) ключ зашит
--   в .ipa → любой может читать/менять/удалять все данные всех пользователей.
--
-- ЧТО ДЕЛАЕТ ЭТА МИГРАЦИЯ:
--   1) Забирает у роли anon прямой доступ к таблицам (пред-авторизационные
--      проверки идут через SECURITY DEFINER RPC и продолжат работать).
--   2) Включает RLS на всех таблицах.
--   3) Добавляет политики для роли authenticated, ограниченные участием в чате
--      и владением строкой. Операции без политики (например прямой INSERT в chats)
--      запрещаются — они и так идут через SECURITY DEFINER RPC, которые обходят RLS.
--
-- ⚠️ ТРЕБУЕТ ПРОВЕРКИ НА Mac: после применения собрать приложение и убедиться,
--    что вход, список чатов, отправка/получение сообщений, медиа, группы,
--    удаление аккаунта работают. Если что-то ломается — точечно ослабить политику.
--    Откат: `alter table ... disable row level security;` + `drop policy ...`.
--
-- Применение: Supabase Dashboard → SQL Editor (или Management API). Идемпотентно
-- по политикам (drop policy if exists перед create).
-- =====================================================================

begin;

-- ── helpers (SECURITY DEFINER, чтобы не зациклить RLS на chat_participants) ──
create or replace function public.is_chat_participant(p_chat_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(
    select 1 from public.chat_participants
    where chat_id = p_chat_id and user_id = auth.uid()
  );
$$;

create or replace function public.shares_chat_with(p_user_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(
    select 1
    from public.chat_participants me
    join public.chat_participants them on them.chat_id = me.chat_id
    where me.user_id = auth.uid() and them.user_id = p_user_id
  );
$$;

-- ── 1) anon не должен иметь прямого доступа к таблицам ──
revoke all on table
  public.users, public.chats, public.chat_participants,
  public.messages, public.message_events
from anon;

-- ── 2) включить RLS ──
alter table public.users             enable row level security;
alter table public.chats             enable row level security;
alter table public.chat_participants enable row level security;
alter table public.messages          enable row level security;
alter table public.message_events    enable row level security;

-- ── 3) политики (роль authenticated) ──

-- users: читать себя и тех, с кем есть общий чат; менять только свой профиль.
-- INSERT — через триггер handle_new_user (definer); DELETE — через delete_user_account (definer).
drop policy if exists users_select on public.users;
create policy users_select on public.users for select to authenticated
  using ( id = auth.uid() or public.shares_chat_with(id) );
drop policy if exists users_update on public.users;
create policy users_update on public.users for update to authenticated
  using ( id = auth.uid() ) with check ( id = auth.uid() );

-- chats: видеть/менять только чаты, где я участник (создание — через RPC).
drop policy if exists chats_select on public.chats;
create policy chats_select on public.chats for select to authenticated
  using ( public.is_chat_participant(id) );
drop policy if exists chats_update on public.chats;
create policy chats_update on public.chats for update to authenticated
  using ( public.is_chat_participant(id) ) with check ( public.is_chat_participant(id) );

-- chat_participants: видеть строки своих чатов; менять (unread_count/mute) только свою строку.
-- INSERT/DELETE — через RPC add/remove_group_participant, create_group_chat, get_or_create_personal_chat (definer).
drop policy if exists cp_select on public.chat_participants;
create policy cp_select on public.chat_participants for select to authenticated
  using ( public.is_chat_participant(chat_id) );
drop policy if exists cp_update on public.chat_participants;
create policy cp_update on public.chat_participants for update to authenticated
  using ( user_id = auth.uid() ) with check ( user_id = auth.uid() );

-- messages: видеть в своих чатах; вставлять от своего имени в свой чат;
-- обновлять (статус, thread_root_id триггером) в своём чате; удалять только свои.
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using ( public.is_chat_participant(chat_id) );
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check ( sender_id = auth.uid() and public.is_chat_participant(chat_id) );
drop policy if exists messages_update on public.messages;
create policy messages_update on public.messages for update to authenticated
  using ( public.is_chat_participant(chat_id) ) with check ( public.is_chat_participant(chat_id) );
drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages for delete to authenticated
  using ( sender_id = auth.uid() );

-- message_events: видеть в своих чатах; вставлять только от своего имени.
drop policy if exists me_select on public.message_events;
create policy me_select on public.message_events for select to authenticated
  using ( public.is_chat_participant(chat_id) );
drop policy if exists me_insert on public.message_events;
create policy me_insert on public.message_events for insert to authenticated
  with check ( actor_id = auth.uid() and public.is_chat_participant(chat_id) );

commit;

-- =====================================================================
-- ОТДЕЛЬНЫЕ СЛЕДУЮЩИЕ ШАГИ (НЕ в этой миграции — обсудить):
--   • apns_token читается co-участником (политика users_select по строке).
--     Минорно. Варианты: вынести apns_token в отдельную таблицу, либо в приложении
--     запрашивать у users только нужные колонки. Колоночный revoke здесь НЕ ставим —
--     он сломал бы `.select()` (SELECT *), который делает приложение.
--   • get_registered_contacts: заменить `SELECT *` на список безопасных колонок
--     (без apns_token); добавить лимит размера массива и rate-limit.
--   • delete_user_account: дополнить удалением файлов Storage (avatars/chat_media)
--     и убедиться в каскаде FK для messages/chats/chat_participants.
--   • Storage: сделать chat_media приватным + signed URL (правки и в приложении).
--   • Ротировать service_role JWT (захардкожен в триггере push) и PAT инспекции.
-- =====================================================================
