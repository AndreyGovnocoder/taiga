-- JWT шаг 1: убрать service_role JWT из push-вебхука (гигиена безопасности).
--
-- ПРОБЛЕМА: триггер "Push On New Message" (AFTER INSERT ON public.messages) — Supabase
-- Database Webhook через supabase_functions.http_request(...). В JSON-заголовке был
-- захардкожен SERVICE_ROLE JWT (god-mode, BYPASSRLS, exp ~2036). Любой, кто прочитает
-- определение триггера (дамп БД, дашборд, инъекция в схему), получал service_role.
--
-- КЛЮЧЕВОЙ ФАКТ: send-push/index.ts использует СВОЙ SUPABASE_SERVICE_ROLE_KEY из env
-- Edge Function. Входящий Authorization функция НЕ читает — он нужен лишь чтобы пройти
-- gateway verify_jwt = true. Значит токену привилегии не нужны — достаточно валидного
-- project-JWT. Новый publishable-ключ (sb_publishable_...) verify_jwt НЕ проходит (не JWT),
-- поэтому используется legacy ANON JWT (role=anon): валиден для gateway, но непривилегирован
-- (ограничен RLS). Так god-mode service_role убран из определения триггера.
--
-- ПРИМЕНЕНО ЖИВЬЁМ через _taiga-db-inspect/apply-jwt-deharden.js (anon берётся из Management
-- API с reveal, smoke send-push = HTTP 200, CREATE OR REPLACE TRIGGER). Проверено
-- verify-push-jwt.js: role=anon. <ANON_JWT> ниже — плейсхолдер (legacy anon-ключ публичен,
-- но в git не бакается; подставляется тулом на лету).
--
-- ОСТАЁТСЯ: шаг 2 (Vault / verify_jwt=false — убрать токен из триггера вовсе, нужен Mac/CLI);
-- шаг 3 (инвалидация утёкшего service_role: ротация JWT-секрета ИЛИ миграция на sb_secret_ —
-- релизное решение пользователя, т.к. ротация секрета ломает anon в клиенте).

create or replace trigger "Push On New Message"
  after insert on public.messages
  for each row
  execute function supabase_functions.http_request(
    'https://rhoyopwzdqtcyawiipya.supabase.co/functions/v1/send-push',
    'POST',
    '{"Content-type":"application/json","Authorization":"Bearer <ANON_JWT role=anon>"}',
    '{}',
    '5000');
