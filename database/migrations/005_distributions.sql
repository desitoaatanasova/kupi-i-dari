-- Купи и Дари — distributions (Phase 11)
-- Engine: MySQL 8 / InnoDB
-- Charset: utf8mb4 / utf8mb4_unicode_ci
-- Hand-written SQL. No ORM.
--
-- Phase 11 records the giving-out of collected goods. A distribution is an
-- append-only event (unlike `collected_quantities`, which is one row per
-- key): the same (location, variant) may be distributed many times, so this
-- table has NO unique key. Each call to POST /api/distributions inserts a new
-- row.
--
-- `distribution_date` is the Europe/Sofia business date, computed by the
-- application at insert time (the same convention as `shifts.shift_date`), so
-- date filtering and future reporting never depend on the MySQL session
-- timezone. `distributed_at` is the underlying TIMESTAMP and is never exposed.
--
-- The location and variant foreign keys use ON DELETE RESTRICT to protect
-- distribution history; `distributed_by` is SET NULL if the staff user is
-- removed. This phase does not enforce distributed <= collected and does not
-- calculate inventory balances.
--
-- Forward-only: there is no DOWN migration in this project; reversal would
-- require a further forward migration or a restore.

CREATE TABLE IF NOT EXISTS distributions (
  distribution_id   INT NOT NULL AUTO_INCREMENT,
  location_id       INT NOT NULL,
  variant_id        INT NOT NULL,
  distribution_date DATE NOT NULL,
  quantity          INT NOT NULL,
  recipient         VARCHAR(160) NULL,
  note              VARCHAR(255) NULL,
  distributed_by    INT NULL,
  distributed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (distribution_id),
  KEY idx_distributions_location (location_id),
  KEY idx_distributions_variant (variant_id),
  KEY idx_distributions_date (distribution_date),
  KEY idx_distributions_distributed_by (distributed_by),
  CONSTRAINT fk_distributions_location FOREIGN KEY (location_id)
    REFERENCES locations (location_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_distributions_variant FOREIGN KEY (variant_id)
    REFERENCES product_variants (variant_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_distributions_distributed_by FOREIGN KEY (distributed_by)
    REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
