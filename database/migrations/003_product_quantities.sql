-- Купи и Дари — collected quantities (Phase 6)
-- Engine: MySQL 8 / InnoDB
-- Charset: utf8mb4 / utf8mb4_unicode_ci
-- Hand-written SQL. No ORM.
--
-- Phase 6 records whole-unit quantities per (location, variant). Shift
-- functionality is not implemented yet, so the mandatory shift dependency is
-- removed: `shift_id` becomes nullable and the uniqueness moves from
-- `(shift_id, location_id, variant_id)` to `(location_id, variant_id)`.
--
-- The `shift_id` column and its foreign key are retained for a potential future
-- shift phase. InnoDB requires an index on the referencing column, so a plain
-- index on `shift_id` is created before the composite unique index that currently
-- supports the foreign key is dropped.
--
-- The table has no production rows at this point (shifts were never
-- implemented), so no data is transformed.

ALTER TABLE collected_quantities
  ADD KEY idx_collected_shift (shift_id);

ALTER TABLE collected_quantities
  DROP INDEX uq_collected;

ALTER TABLE collected_quantities
  ADD UNIQUE KEY uq_collected_location_variant (location_id, variant_id);

ALTER TABLE collected_quantities
  MODIFY COLUMN shift_id INT NULL;
