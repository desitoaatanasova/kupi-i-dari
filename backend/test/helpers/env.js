'use strict';

require('dotenv').config();

process.env.NODE_ENV = process.env.NODE_ENV || 'test';
process.env.TZ = process.env.TZ || 'Europe/Sofia';
process.env.DB_NAME = process.env.DB_NAME_TEST || 'kupi_i_dari_test';

// Explicit test-only JWT secret. Never a real production secret.
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-only-jwt-secret';
process.env.JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '60m';

// Generous auth limits by default so functional tests are not rate-limited.
// The dedicated rate-limit test overrides these before loading the app.
if (process.env.AUTH_RATE_LIMIT_WINDOW_MS === undefined) {
  process.env.AUTH_RATE_LIMIT_WINDOW_MS = '900000';
}
if (process.env.AUTH_RATE_LIMIT_MAX === undefined) {
  process.env.AUTH_RATE_LIMIT_MAX = '10000';
}
if (process.env.AUTH_VOLUNTEER_RATE_LIMIT_MAX === undefined) {
  process.env.AUTH_VOLUNTEER_RATE_LIMIT_MAX = '10000';
}
if (process.env.AUTH_ADMIN_WRITE_RATE_LIMIT_MAX === undefined) {
  process.env.AUTH_ADMIN_WRITE_RATE_LIMIT_MAX = '10000';
}
