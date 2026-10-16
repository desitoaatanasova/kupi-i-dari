'use strict';

const path = require('path');
require('dotenv').config();

const BACKEND_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(BACKEND_ROOT, '..');

function toInt(value, fallback) {
  const parsed = parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

// Parse a duration such as "60m", "1h", "7d", "3600s" or "3600" into seconds.
// Used for JWT expiry so the same value drives signing and the API response.
function parseDurationSeconds(value, fallbackSeconds) {
  if (value === undefined || value === null || value === '') return fallbackSeconds;
  const text = String(value).trim();
  if (/^\d+$/.test(text)) return parseInt(text, 10);
  const match = /^(\d+)\s*(s|m|h|d)$/i.exec(text);
  if (!match) return fallbackSeconds;
  const multipliers = { s: 1, m: 60, h: 3600, d: 86400 };
  return parseInt(match[1], 10) * multipliers[match[2].toLowerCase()];
}

const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '60m';

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

  jwt: {
    secret: process.env.JWT_SECRET || '',
    expiresIn: JWT_EXPIRES_IN,
    expiresInSeconds: parseDurationSeconds(JWT_EXPIRES_IN, 3600),
  },

  authRateLimit: {
    windowMs: toInt(process.env.AUTH_RATE_LIMIT_WINDOW_MS, 15 * 60 * 1000),
    loginMax: toInt(process.env.AUTH_RATE_LIMIT_MAX, 10),
    volunteerMax: toInt(process.env.AUTH_VOLUNTEER_RATE_LIMIT_MAX, 20),
    adminWriteMax: toInt(process.env.AUTH_ADMIN_WRITE_RATE_LIMIT_MAX, 30),
  },

  corsOrigins: (process.env.CORS_ORIGIN || '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),

  rateLimit: {
    windowMs: toInt(process.env.RATE_LIMIT_WINDOW_MS, 900000),
    max: toInt(process.env.RATE_LIMIT_MAX, 300),
  },

  migrationsDir: path.join(REPO_ROOT, 'database', 'migrations'),

  seedAdmin: {
    phone: process.env.SEED_ADMIN_PHONE || '+359888000001',
    password: process.env.SEED_ADMIN_PASSWORD || '',
    firstName: process.env.SEED_ADMIN_FIRST_NAME || 'Администратор',
    lastName: process.env.SEED_ADMIN_LAST_NAME || 'Купи и Дари',
  },
};

// Fail fast for the HTTP server when auth configuration is unusable. Deliberately
// does not run in tests and is not called by the migration/seed scripts, so those
// workflows do not require a JWT secret.
function assertAuthConfig() {
  if (config.env === 'test') return;

  if (!config.jwt.secret) {
    throw new Error(
      'JWT_SECRET is missing or empty. Set it in backend/.env before starting the API.'
    );
  }
  if (!Number.isInteger(config.jwt.expiresInSeconds) || config.jwt.expiresInSeconds <= 0) {
    throw new Error(
      'JWT_EXPIRES_IN must resolve to a positive number of seconds (e.g. "60m" or 3600).'
    );
  }
  const { windowMs, loginMax, volunteerMax, adminWriteMax } = config.authRateLimit;
  if (![windowMs, loginMax, volunteerMax, adminWriteMax].every((n) => Number.isInteger(n) && n > 0)) {
    throw new Error(
      'Authentication rate-limit values (AUTH_RATE_LIMIT_WINDOW_MS, ' +
        'AUTH_RATE_LIMIT_MAX, AUTH_VOLUNTEER_RATE_LIMIT_MAX, ' +
        'AUTH_ADMIN_WRITE_RATE_LIMIT_MAX) must be positive integers.'
    );
  }
}

module.exports = config;
module.exports.assertAuthConfig = assertAuthConfig;
