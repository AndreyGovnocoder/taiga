-- =====================================================================
-- «Очистить чат» / «Удалить чат» (персистентно, per-user) + полноразмерные аватары.
--
-- ЗАЧЕМ:
--   1) Clear/Delete чата раньше были ЧИСТО ЛОКАЛЬНЫМИ → любой ресинк с сервера
--      (fetchChats/fetchMessages) возвращал чат и сообщения. Нужна персистентная
--      per-user отметка «очищено/удалено до момента T», которую клиент читает и
--      применяет как фильтр. Семантика «удалить переписку»: старое скрыто, новое
--      сообщение (created_at > отметки) оживляет чат.
--   2) avatar_url_full: храним полноразмерную версию аватара (профиль/fullscreen),
--      а avatar_url остаётся компактной тумбой (список/шапка).
--
-- МОДЕЛЬ ДОСТУПА: метки лежат в chat_participants (per-user-per-chat). Запись —
--   через SECURITY DEFINER RPC (как mark_chat_read/block_user), now() — серверное
--   время (без clock skew). Чтение — обычным .select() (политика cp_select уже
--   отдаёт свои строки участника).
--
-- БЕЗОПАСНОСТЬ: RPC меняют ТОЛЬКО строку вызывающего (WHERE user_id = auth.uid()).
--   Чужие чаты/участники не затрагиваются. Прямого DELETE участника НЕТ (это сломало бы
--   1:1 get_or_create и доступ собеседника) — удаление = пометка deleted_at, не выход.
--
-- ⚠️ ПРИМЕНИТЬ ПЕРВЫМ (до выката клиента): Supabase Dashboard → SQL Editor.
--   Клиент к отсутствующим колонкам forward-совместим (Codable optional → nil), НЕ упадёт,
--   но RPC clear_chat/delete_chat и сохранение avatar_url_full заработают только после
--   применения. Идемпотентно (IF NOT EXISTS / CREATE OR REPLACE).
--   Откат: drop function clear_chat/delete_chat; alter table ... drop column ... .
-- =====================================================================

begin;

-- ── 1) Колонки ──
alter table public.chat_participants add column if not exists cleared_at timestamptz;
alter table public.chat_participants add column if not exists deleted_at timestamptz;
alter table public.users add column if not exists avatar_url_full text;

-- ── 2) RPC: очистка/удаление чата для ТЕКУЩЕГО пользователя ──

-- «Очистить чат»: пометить cleared_at = now() и обнулить unread. Клиент скрывает сообщения
-- с created_at <= cleared_at.
create or replace function public.clear_chat(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Не авторизован' using errcode = '28000'; end if;
  update public.chat_participants
     set cleared_at = now(), unread_count = 0
   where chat_id = p_chat_id and user_id = uid;
end; $$;

-- «Удалить чат»: пометить cleared_at = now() И deleted_at = now() (+ обнулить unread). Клиент
-- скрывает сам чат, пока последнее сообщение <= deleted_at; более новое сообщение оживляет чат
-- (показываются только сообщения после cleared_at). Участие в чате НЕ удаляется (иначе ломается 1:1).
create or replace function public.delete_chat(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Не авторизован' using errcode = '28000'; end if;
  update public.chat_participants
     set cleared_at = now(), deleted_at = now(), unread_count = 0
   where chat_id = p_chat_id and user_id = uid;
end; $$;

-- «Снять удаление»: при ЯВНОМ открытии удалённого чата из Контактов (get_or_create) снимаем
-- deleted_at, чтобы чат снова материализовался. cleared_at СОХРАНЯЕМ — история остаётся
-- очищенной (открывается пустой, готов к новой переписке).
create or replace function public.undelete_chat(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Не авторизован' using errcode = '28000'; end if;
  update public.chat_participants
     set deleted_at = null
   where chat_id = p_chat_id and user_id = uid;
end; $$;

alter function public.clear_chat(uuid) owner to postgres;
alter function public.delete_chat(uuid) owner to postgres;
alter function public.undelete_chat(uuid) owner to postgres;

revoke all on function public.clear_chat(uuid) from public, anon;
revoke all on function public.delete_chat(uuid) from public, anon;
revoke all on function public.undelete_chat(uuid) from public, anon;
grant execute on function public.clear_chat(uuid) to authenticated;
grant execute on function public.delete_chat(uuid) to authenticated;
grant execute on function public.undelete_chat(uuid) to authenticated;

commit;

-- =====================================================================
-- ПРИМЕЧАНИЯ:
--   • Реинсталл/мультидевайс: метки серверные → переживают переустановку и видны
--     на втором устройстве (в отличие от чисто локального варианта).
--   • Группы: «Удалить чат» из списка = пометка deleted_at (локальное скрытие, остаёшься
--     участником). Выход из группы — отдельное действие (remove_group_participant).
--   • avatar_url_full для групп НЕ вводим: групповой аватар грузится в одном (повышенном)
--     разрешении, fullscreen для групп не требуется.
-- =====================================================================
