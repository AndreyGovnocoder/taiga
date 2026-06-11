-- Кластер #3 (аудит): unread high-water mark — устранить TOCTOU (set=0 против серверного +1)
-- и подготовить согласованный счётчик. send-push НЕ трогаем (он читает chat_participants.unread_count).
-- Аддитивно и fail-safe: новый столбец NULL → поведение инкремента идентично прежнему до первого read.

begin;

-- 1. Высокая отметка прочитанного на участнике чата.
alter table public.chat_participants add column if not exists last_read_at timestamptz;

-- 2. handle_new_message: инкремент unread только для сообщений ПОЗЖЕ отметки прочитанного.
--    Идентично прежней функции; добавлено условие (last_read_at is null or NEW.created_at > last_read_at).
--    Гейт может только ПОДАВИТЬ лишний инкремент, никогда не ломает INSERT сообщения.
create or replace function public.handle_new_message()
returns trigger language plpgsql security definer as $$
begin
  update public.chats set
    last_message_id        = NEW.id,
    last_message_text      = COALESCE(NEW.content_text, ''),
    last_message_at        = NEW.created_at,
    last_message_sender_id = NEW.sender_id,
    last_message_type      = NEW.content_type
  where id = NEW.chat_id;

  update public.chat_participants
  set unread_count = unread_count + 1
  where chat_id = NEW.chat_id
    and user_id != NEW.sender_id
    and is_muted = false
    and (last_read_at is null or NEW.created_at > last_read_at);

  return NEW;
end;
$$;

-- 3. Идемпотентная пометка чата прочитанным: атомарно двигает отметку (GREATEST) и обнуляет счётчик.
--    Заменяет racy клиентский прямой update chat_participants set unread_count=0.
create or replace function public.mark_chat_read(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Не авторизован' using errcode = '28000'; end if;
  update public.chat_participants
  set last_read_at = greatest(coalesce(last_read_at, to_timestamp(0)), now()),
      unread_count = 0
  where chat_id = p_chat_id and user_id = uid;
end;
$$;
alter function public.mark_chat_read(uuid) owner to postgres;
revoke all on function public.mark_chat_read(uuid) from public, anon;
grant execute on function public.mark_chat_read(uuid) to authenticated;

commit;
