'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const ADMIN_PHONE = '+359881000001';
const RESP_PHONE = '+359881000002';
const VOL_PHONE = '+359881000003';
const SAFE_KEYS = ['id', 'phone', 'firstName', 'lastName', 'role', 'isActive', 'mustChangePassword'];

let server;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanUsers();
});

async function seedStaff(phone, role, isActive = true) {
  return auth.createUser({
    phone,
    firstName: 'Служител',
    lastName: 'Тестов',
    role,
    password: auth.TEST_PASSWORD,
    isActive,
  });
}

test('valid ADMIN login returns token and safe profile', async () => {
  await seedStaff(ADMIN_PHONE, 'ADMIN');
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: ADMIN_PHONE,
    password: auth.TEST_PASSWORD,
  });

  assert.equal(res.status, 200);
  assert.equal(res.body.tokenType, 'Bearer');
  assert.equal(typeof res.body.token, 'string');
  assert.equal(typeof res.body.expiresIn, 'number');
  assert.equal(res.body.expiresIn, 3600);
  assert.deepEqual(Object.keys(res.body.user).sort(), [...SAFE_KEYS].sort());
  assert.equal(res.body.user.role, 'ADMIN');
  assert.equal(res.body.user.phone, ADMIN_PHONE);
  assert.equal(res.body.user.isActive, true);
  assert.equal(res.body.user.mustChangePassword, false);
  assert.equal(res.body.user.password_hash, undefined);
  assert.equal(res.body.user.tokenVersion, undefined);
});

test('valid RESPONSIBLE login succeeds', async () => {
  await seedStaff(RESP_PHONE, 'RESPONSIBLE');
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: RESP_PHONE,
    password: auth.TEST_PASSWORD,
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.user.role, 'RESPONSIBLE');
});

test('incorrect password returns generic 401', async () => {
  await seedStaff(ADMIN_PHONE, 'ADMIN');
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: ADMIN_PHONE,
    password: 'WrongPassword!',
  });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('unknown phone returns the same generic 401', async () => {
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: '+359889999999',
    password: auth.TEST_PASSWORD,
  });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('volunteer account cannot use staff login', async () => {
  await auth.createUser({ phone: VOL_PHONE, role: 'VOLUNTEER' });
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: VOL_PHONE,
    password: auth.TEST_PASSWORD,
  });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('inactive staff account is rejected with ACCOUNT_DISABLED', async () => {
  await seedStaff(ADMIN_PHONE, 'ADMIN', false);
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: ADMIN_PHONE,
    password: auth.TEST_PASSWORD,
  });
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'ACCOUNT_DISABLED');
});

test('missing, empty and non-string fields return 400', async () => {
  for (const body of [
    {},
    { phone: ADMIN_PHONE },
    { password: 'x' },
    { phone: '', password: 'x' },
    { phone: ADMIN_PHONE, password: '' },
    { phone: 123, password: 'x' },
    { phone: ADMIN_PHONE, password: 123 },
    { phone: null, password: null },
  ]) {
    const res = await auth.postJson(server.baseUrl, '/api/auth/login', body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});

test('unknown field returns 400', async () => {
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: ADMIN_PHONE,
    password: 'x',
    role: 'ADMIN',
  });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('malformed phone returns 400', async () => {
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: 'not-a-phone',
    password: 'x',
  });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('successful login updates last_login_at', async () => {
  const userId = await seedStaff(ADMIN_PHONE, 'ADMIN');
  const [before] = await auth.pool.query('SELECT last_login_at FROM users WHERE user_id = ?', [userId]);
  assert.equal(before[0].last_login_at, null);

  await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: ADMIN_PHONE,
    password: auth.TEST_PASSWORD,
  });

  const [after] = await auth.pool.query('SELECT last_login_at FROM users WHERE user_id = ?', [userId]);
  assert.ok(after[0].last_login_at instanceof Date || after[0].last_login_at !== null);
});
