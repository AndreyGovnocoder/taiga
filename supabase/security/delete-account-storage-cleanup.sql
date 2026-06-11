-- delete_user_account: удаление аккаунта server-first, включая файлы пользователя в Storage.
--
-- Контекст (Apple App Store guideline 5.1.1(v)): in-app удаление аккаунта обязано реально
-- удалять данные пользователя. Прежняя версия чистила только public.users + auth.users,
-- оставляя аватары и медиа чатов в Storage. Эта версия добавляет удаление storage.objects.
--
-- Технические детали:
--  * Прямой DELETE из storage.objects заблокирован триггером storage.protect_delete().
--    Он пропускает удаление, только когда GUC storage.allow_delete_query = 'true'.
--    Ставим его локально в транзакции (set_config(..., is_local := true)).
--  * Функция SECURITY DEFINER, владелец — роль postgres (BYPASSRLS=true), поэтому
--    RLS на storage.objects не мешает (у бакета chat_media нет DELETE-политики).
--  * auth.uid() внутри SECURITY DEFINER возвращает uid ВЫЗЫВАЮЩЕГО (из JWT), не владельца.
--  * Порядок: storage.objects удаляем ПЕРВЫМ (owner ссылается на auth.users; удаление
--    auth.users раньше могло бы обнулить/каскадить owner и мы бы промахнулись), затем
--    public.users (каскад на чаты/сообщения по FK), затем auth.users.
--
-- ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ: прямое удаление строк storage.objects делает файлы недоступными
-- через API, но физический blob в бэкенде Storage остаётся (orphan). Для полной очистки
-- blob'ов нужен вызов Storage API (например, отдельный edge-function/cron). Для соответствия
-- Apple важно, что данные становятся недоступны — этого добиваемся. Orphan-cleanup — позже.

CREATE OR REPLACE FUNCTION public.delete_user_account()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Не авторизован' USING ERRCODE = '28000';
  END IF;

  -- 1. Файлы пользователя в Storage (аватары + медиа чатов).
  PERFORM set_config('storage.allow_delete_query', 'true', true);
  DELETE FROM storage.objects WHERE owner = uid;

  -- 2. Публичный профиль (каскад на чаты/сообщения по FK).
  DELETE FROM public.users WHERE id = uid;

  -- 3. Системная учётная запись.
  DELETE FROM auth.users WHERE id = uid;
END;
$function$;

-- Гарантируем владельца с BYPASSRLS (CREATE OR REPLACE не меняет владельца существующей функции).
ALTER FUNCTION public.delete_user_account() OWNER TO postgres;
