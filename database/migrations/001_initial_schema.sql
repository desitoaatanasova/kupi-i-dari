-- Купи и Дари — initial schema (Phase 1)
-- Engine: MySQL 8 / InnoDB
-- Charset: utf8mb4 / utf8mb4_unicode_ci
-- Hand-written SQL. No ORM.
--
-- Notes:
--  * Shifts may cover MULTIPLE locations -> junction table `shift_locations`.
--  * Users are identified by phone. Volunteers may register without a password
--    (password_hash is NULLable); RESPONSIBLE/ADMIN accounts have passwords.
--  * collected_quantities.quantity is INT (whole units) until the unit model
--    decision is finalised.

CREATE TABLE IF NOT EXISTS users (
  user_id        INT NOT NULL AUTO_INCREMENT,
  phone          VARCHAR(20)  NOT NULL,
  password_hash  VARCHAR(255) NULL,
  first_name     VARCHAR(60)  NOT NULL,
  last_name      VARCHAR(60)  NOT NULL,
  role           ENUM('VOLUNTEER','RESPONSIBLE','ADMIN') NOT NULL DEFAULT 'VOLUNTEER',
  is_active      TINYINT(1)   NOT NULL DEFAULT 1,
  created_by     INT          NULL,
  created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  UNIQUE KEY uq_users_phone (phone),
  KEY idx_users_role (role),
  KEY idx_users_active (is_active),
  KEY idx_users_created_by (created_by),
  CONSTRAINT fk_users_created_by FOREIGN KEY (created_by)
    REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS locations (
  location_id  INT NOT NULL AUTO_INCREMENT,
  name         VARCHAR(120) NOT NULL,
  address      VARCHAR(255) NULL,
  city         VARCHAR(80)  NULL,
  is_active    TINYINT(1)   NOT NULL DEFAULT 1,
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (location_id),
  UNIQUE KEY uq_locations_name (name),
  KEY idx_locations_active (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Which RESPONSIBLE users manage which locations.
CREATE TABLE IF NOT EXISTS responsible_locations (
  responsible_location_id INT NOT NULL AUTO_INCREMENT,
  user_id      INT NOT NULL,
  location_id  INT NOT NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (responsible_location_id),
  UNIQUE KEY uq_responsible_location (user_id, location_id),
  KEY idx_responsible_locations_location (location_id),
  CONSTRAINT fk_resp_loc_user FOREIGN KEY (user_id)
    REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_resp_loc_location FOREIGN KEY (location_id)
    REFERENCES locations (location_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS shifts (
  shift_id    INT NOT NULL AUTO_INCREMENT,
  title       VARCHAR(120) NULL,
  shift_date  DATE NOT NULL,
  start_time  TIME NOT NULL,
  end_time    TIME NOT NULL,
  status      ENUM('DRAFT','OPEN','CLOSED','CANCELLED') NOT NULL DEFAULT 'DRAFT',
  created_by  INT NULL,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (shift_id),
  KEY idx_shifts_date (shift_date),
  KEY idx_shifts_status (status),
  KEY idx_shifts_created_by (created_by),
  CONSTRAINT fk_shifts_created_by FOREIGN KEY (created_by)
    REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- A shift can take place at one or more locations.
CREATE TABLE IF NOT EXISTS shift_locations (
  shift_location_id INT NOT NULL AUTO_INCREMENT,
  shift_id     INT NOT NULL,
  location_id  INT NOT NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (shift_location_id),
  UNIQUE KEY uq_shift_location (shift_id, location_id),
  KEY idx_shift_locations_location (location_id),
  CONSTRAINT fk_shift_locations_shift FOREIGN KEY (shift_id)
    REFERENCES shifts (shift_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_shift_locations_location FOREIGN KEY (location_id)
    REFERENCES locations (location_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS shift_registrations (
  registration_id INT NOT NULL AUTO_INCREMENT,
  shift_id    INT NOT NULL,
  user_id     INT NOT NULL,
  status      ENUM('REGISTERED','CANCELLED') NOT NULL DEFAULT 'REGISTERED',
  registered_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (registration_id),
  UNIQUE KEY uq_shift_registration (shift_id, user_id),
  KEY idx_shift_registrations_user (user_id),
  CONSTRAINT fk_shift_registrations_shift FOREIGN KEY (shift_id)
    REFERENCES shifts (shift_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_shift_registrations_user FOREIGN KEY (user_id)
    REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS products (
  product_id   INT NOT NULL AUTO_INCREMENT,
  name         VARCHAR(120) NOT NULL,
  category     VARCHAR(80)  NULL,
  is_active    TINYINT(1)   NOT NULL DEFAULT 1,
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (product_id),
  UNIQUE KEY uq_products_name (name),
  KEY idx_products_category (category),
  KEY idx_products_active (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS product_variants (
  variant_id   INT NOT NULL AUTO_INCREMENT,
  product_id   INT NOT NULL,
  unit_label   VARCHAR(40) NOT NULL,
  unit_value   DECIMAL(10,3) NULL,
  is_active    TINYINT(1)   NOT NULL DEFAULT 1,
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (variant_id),
  UNIQUE KEY uq_product_variant (product_id, unit_label),
  KEY idx_product_variants_product (product_id),
  CONSTRAINT fk_product_variants_product FOREIGN KEY (product_id)
    REFERENCES products (product_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS collected_quantities (
  collected_quantity_id INT NOT NULL AUTO_INCREMENT,
  shift_id     INT NOT NULL,
  location_id  INT NOT NULL,
  variant_id   INT NOT NULL,
  quantity     INT NOT NULL DEFAULT 0,
  recorded_by  INT NULL,
  recorded_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (collected_quantity_id),
  UNIQUE KEY uq_collected (shift_id, location_id, variant_id),
  KEY idx_collected_location (location_id),
  KEY idx_collected_variant (variant_id),
  KEY idx_collected_recorded_by (recorded_by),
  CONSTRAINT fk_collected_shift FOREIGN KEY (shift_id)
    REFERENCES shifts (shift_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_collected_location FOREIGN KEY (location_id)
    REFERENCES locations (location_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_collected_variant FOREIGN KEY (variant_id)
    REFERENCES product_variants (variant_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_collected_recorded_by FOREIGN KEY (recorded_by)
    REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
