-- Купи и Дари — auth core (Phase 2)
-- Engine: MySQL 8 / InnoDB
-- Charset: utf8mb4 / utf8mb4_unicode_ci
-- Hand-written SQL. No ORM.
--
-- Adds the authentication/revocation fields required by Phase 2:
--  * must_change_password — flag surfaced in the safe profile; the actual
--    password-change/reset workflow is deferred to a later phase.
--  * token_version       — incremented on logout to revoke previously issued JWT.
--  * last_login_at       — updated on successful staff login / volunteer identify.

ALTER TABLE users
  ADD COLUMN must_change_password TINYINT(1)   NOT NULL DEFAULT 0 AFTER is_active,
  ADD COLUMN token_version        INT          NOT NULL DEFAULT 0 AFTER must_change_password,
  ADD COLUMN last_login_at        TIMESTAMP    NULL                AFTER token_version;
