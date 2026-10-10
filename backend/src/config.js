'use strict';

const path = require('path');
require('dotenv').config();

const BACKEND_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(BACKEND_ROOT, '..');

function toInt(value, fallback) {
  const parsed = parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

const config = {
  env: process.env.NODE_ENV || 'development',
  port: toInt(process.env.PORT, 3001),
  timezone: process.env.TZ || 'Europe/Sofia',

  db: {
    host: process.env.DB_HOST || 'localhost',
    port: toInt(process.env.DB_PORT, 3306),
    user: process.env.DB_USER || 'root',
    password: process.env.DB_PASSWORD || '',
    name: process.env.DB_NAME || 'kupi_i_dari',
    charset: 'utf8mb4',
  },

  dbTest: process.env.DB_NAME_TEST || 'kupi_i_dari_test',

  jwtSecret: process.env.JWT_SECRET || '',

  corsOrigins: (process.env.CORS_ORIGIN || '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),

  rateLimit: {
    windowMs: toInt(process.env.RATE_LIMIT_WINDOW_MS, 15 * 60 * 1000),
    max: toInt(process.env.RATE_LIMIT_MAX, 300),
  },

  migrationsDir:
    process.env.MIGRATIONS_DIR || path.resolve(REPO_ROOT, 'database', 'migrations'),

  seedAdmin: {
    phone: process.env.SEED_ADMIN_PHONE || '+359888000001',
    password: process.env.SEED_ADMIN_PASSWORD || '',
    firstName: process.env.SEED_ADMIN_FIRST_NAME || 'Администратор',
    lastName: process.env.SEED_ADMIN_LAST_NAME || 'Купи и Дари',
  },
};

module.exports = config;
