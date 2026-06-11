-- UGC-модерация (Apple App Store guideline 1.2): блокировка пользователей + жалобы на контент.
--
-- Модель доступа: таблицы blocks/content_reports закрыты от прямого клиентского доступа
-- (RLS on + grants revoked); вся работа — через SECURITY DEFINER RPC (владелец postgres, BYPASSRLS),
-- как у существующих get_registered_contacts / get_or_create_personal_chat.
--
-- Enforcement: B+A (прагматично). Сервер: блокировка убирает пользователя из поиска контактов
-- (патч get_registered_contacts, в обе стороны). Остальная фильтрация — клиентская.
-- ИЗВЕСТНЫЙ ГЭП (отложено в hardening-итерацию, Tier C): RLS на messages/users пока НЕ знает о блокировках,
-- поэтому заблокированный, имея общий чат, технически ещё может читать/писать в него напрямую, а
-- edge-функция send-push шлёт уведомление. Это закрывается позже (RLS-предикаты + патч send-push).

BEGIN;

-- ============ Таблицы ============
CREATE TABLE IF NOT EXISTS public.blocks (
  blocker_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON public.blocks(blocked_id);

CREATE TABLE IF NOT EXISTS public.content_reports (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  reporter_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reported_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  message_id uuid,
  chat_id uuid,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- RLS: доступ только через RPC ниже. Прямого клиентского доступа к таблицам нет.
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_reports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.blocks FROM anon, authenticated;
REVOKE ALL ON public.content_reports FROM anon, authenticated;

-- ============ RPC (SECURITY DEFINER, owner=postgres) ============
CREATE OR REPLACE FUNCTION public.block_user(p_blocked_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Не авторизован' USING ERRCODE = '28000'; END IF;
  IF uid = p_blocked_id THEN RAISE EXCEPTION 'Нельзя заблокировать себя' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.blocks(blocker_id, blocked_id) VALUES (uid, p_blocked_id)
    ON CONFLICT (blocker_id, blocked_id) DO NOTHING;
END; $$;

CREATE OR REPLACE FUNCTION public.unblock_user(p_blocked_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Не авторизован' USING ERRCODE = '28000'; END IF;
  DELETE FROM public.blocks WHERE blocker_id = uid AND blocked_id = p_blocked_id;
END; $$;

-- Возвращает профили заблокированных (в обход users-RLS — иначе не показать тех, с кем нет общего чата).
CREATE OR REPLACE FUNCTION public.get_blocked_users()
RETURNS SETOF public.users LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Не авторизован' USING ERRCODE = '28000'; END IF;
  RETURN QUERY
    SELECT u.* FROM public.users u
    JOIN public.blocks b ON b.blocked_id = u.id
    WHERE b.blocker_id = uid;
END; $$;

CREATE OR REPLACE FUNCTION public.report_content(p_reported_user_id uuid, p_message_id uuid, p_chat_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Не авторизован' USING ERRCODE = '28000'; END IF;
  INSERT INTO public.content_reports(reporter_id, reported_user_id, message_id, chat_id, reason)
    VALUES (uid, p_reported_user_id, p_message_id, p_chat_id, left(coalesce(p_reason, ''), 500));
END; $$;

ALTER FUNCTION public.block_user(uuid) OWNER TO postgres;
ALTER FUNCTION public.unblock_user(uuid) OWNER TO postgres;
ALTER FUNCTION public.get_blocked_users() OWNER TO postgres;
ALTER FUNCTION public.report_content(uuid, uuid, uuid, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.block_user(uuid) FROM public, anon;
REVOKE ALL ON FUNCTION public.unblock_user(uuid) FROM public, anon;
REVOKE ALL ON FUNCTION public.get_blocked_users() FROM public, anon;
REVOKE ALL ON FUNCTION public.report_content(uuid, uuid, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.block_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unblock_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_blocked_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_content(uuid, uuid, uuid, text) TO authenticated;

-- ============ Патч: исключить block-связь (в обе стороны) из поиска контактов ============
CREATE OR REPLACE FUNCTION public.get_registered_contacts(phone_numbers text[])
RETURNS SETOF users LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT * FROM users u
  WHERE u.phone_number = ANY(phone_numbers)
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      WHERE (b.blocker_id = auth.uid() AND b.blocked_id = u.id)
         OR (b.blocker_id = u.id AND b.blocked_id = auth.uid())
    );
END; $$;
ALTER FUNCTION public.get_registered_contacts(text[]) OWNER TO postgres;

COMMIT;
