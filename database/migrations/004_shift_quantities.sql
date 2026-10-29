-- Купи и Дари — shift-linked quantities (Phase 8)
-- Engine: MySQL 8 / InnoDB
-- Charset: utf8mb4 / utf8mb4_unicode_ci
-- Hand-written SQL. No ORM.
--
-- Uniqueness moves from (location_id, variant_id) to
-- (shift_id, location_id, variant_id) so the same variant at the same location
-- can hold a separate quantity per shift. This is required for accurate
-- per-shift reporting once volunteers record quantities during shifts.
--
-- `shift_id` stays NULLable: pre-existing unlinked rows (Phase 6, written with
-- shift_id = NULL) are preserved exactly as they are, are never backfilled with
-- invented shift associations, and remain readable and correctable through the
-- existing quantity endpoints (`shiftId: null` in the safe response).
--
-- MySQL NULL semantics: a composite UNIQUE index does NOT prevent duplicate
-- rows when any indexed column is NULL (NULL != NULL for uniqueness). The new
-- index therefore does not by itself guarantee one unlinked row per
-- (location, variant). The application preserves that invariant by
-- serializing unlinked upserts on a FOR UPDATE lock of the location row before
-- any read or write (see the location-lock path in
-- backend/src/services/quantities.js). New shift-based rows always set
-- `shift_id`, so they are protected by this unique index itself.
--
-- The plain idx_collected_shift index is dropped: the leading column of the
-- new composite unique index already provides an index on `shift_id` for the
-- existing fk_collected_shift foreign key. All foreign keys and columns are
-- otherwise unchanged. No data is transformed.
--
-- Forward-only: there is no DOWN migration in this project; reversal would
-- require a further forward migration or a restore.

ALTER TABLE collected_quantities
  DROP INDEX uq_collected_location_variant,
  DROP INDEX idx_collected_shift,
  ADD UNIQUE KEY uq_collected_shift_location_variant (shift_id, location_id, variant_id);
