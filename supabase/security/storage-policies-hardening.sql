-- Ужесточение RLS-политик Storage (storage.objects). Tier 1: закрытие дыр прав записи.
--
-- Проблемы до фикса (live):
--   1) "Allow all operations for avatars bucket" (cmd=ALL, roles=public) — КТО УГОДНО (вкл. анонимов)
--      мог удалить/перезаписать ЛЮБОЙ аватар.
--   2) "Allow public uploads" (INSERT, roles=public) — кто угодно мог заливать в chat_media.
--
-- Фикс: ЧТЕНИЕ остаётся публичным (бакеты публичные, загрузка картинок в клиенте не ломается —
-- CachedImageView грузит по public URL без авторизации). ЗАПИСЬ (INSERT/UPDATE/DELETE) — только
-- роль authenticated и только свои файлы (owner = auth.uid()).
--
-- Полная приватность (приватные бакеты + signed URL вместо public URL) — отдельная итерация (Tier 2),
-- требует рефакторинга загрузки на клиенте и проверки на устройстве.
--
-- Применяется ролью postgres (BYPASSRLS) через Management API. Транзакция — для атомарности.

BEGIN;

-- 1. Снять опасные политики.
DROP POLICY IF EXISTS "Allow all operations for avatars bucket" ON storage.objects;
DROP POLICY IF EXISTS "Allow public uploads" ON storage.objects;

-- 2. avatars: публичное чтение + запись только владельцем.
DROP POLICY IF EXISTS "avatars_public_read" ON storage.objects;
CREATE POLICY "avatars_public_read" ON storage.objects
  FOR SELECT TO public USING (bucket_id = 'avatars');

DROP POLICY IF EXISTS "avatars_owner_insert" ON storage.objects;
CREATE POLICY "avatars_owner_insert" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'avatars' AND owner = auth.uid());

DROP POLICY IF EXISTS "avatars_owner_update" ON storage.objects;
CREATE POLICY "avatars_owner_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'avatars' AND owner = auth.uid())
  WITH CHECK (bucket_id = 'avatars' AND owner = auth.uid());

DROP POLICY IF EXISTS "avatars_owner_delete" ON storage.objects;
CREATE POLICY "avatars_owner_delete" ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'avatars' AND owner = auth.uid());

-- 3. chat_media: оставляем существующую "Allow public read" (SELECT public),
--    запись — только владельцем.
DROP POLICY IF EXISTS "chat_media_owner_insert" ON storage.objects;
CREATE POLICY "chat_media_owner_insert" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'chat_media' AND owner = auth.uid());

DROP POLICY IF EXISTS "chat_media_owner_update" ON storage.objects;
CREATE POLICY "chat_media_owner_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'chat_media' AND owner = auth.uid())
  WITH CHECK (bucket_id = 'chat_media' AND owner = auth.uid());

DROP POLICY IF EXISTS "chat_media_owner_delete" ON storage.objects;
CREATE POLICY "chat_media_owner_delete" ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'chat_media' AND owner = auth.uid());

COMMIT;
