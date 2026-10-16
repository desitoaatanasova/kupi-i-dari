'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const config = require('../src/config');
const app = require('../src/app');

const STAFF_PHONE = '+359883000001';
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

async function loginAdmin() {
  await auth.createUser({
    phone: STAFF_PHONE,
    firstName: 'Админ',
    lastName: 'Тестов',
    role: 'ADMIN',
    password: auth.TEST_PASSWORD,
  });
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: STAFF_PHONE,
    password: auth.TEST_PASSWORD,
  });
  return res.body.token;
}

function sign(payload, options = {}) {
  const { secret = config.jwt.secret, algorithm = 'HS256', expiresIn = 3600 } = options;
  return jwt.sign(payload, secret, { algorithm, expiresIn });
}

test('valid token returns the safe profile from the database', async () => {
  const token = await loginAdmin();
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [...SAFE_KEYS].sort());
  assert.equal(res.body.role, 'ADMIN');
  assert.equal(res.body.phone, STAFF_PHONE);
  assert.equal(res.body.isActive, true);
  assert.equal(res.body.mustChangePassword, false);
  assert.ok(!('password_hash' in res.body));
  assert.ok(!('passwordHash' in res.body));
  assert.ok(!('token_version' in res.body));
  assert.ok(!('tokenVersion' in res.body));
});

test('missing Bearer token returns 401', async () => {
  const res = await auth.getJson(server.baseUrl, '/api/auth/me');
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('malformed token returns 401', async () => {
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', 'not-a-jwt');
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('expired token returns 401', async () => {
  const token = await loginAdmin();
  const expired = sign({ sub: 1, role: 'ADMIN', tv: 0 }, { expiresIn: -60 });
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', expired);
  assert.equal(res.status, 401);
  assert.ok(token);
});

test('token signed with the wrong secret returns 401', async () => {
  const token = sign({ sub: 1, role: 'ADMIN', tv: 0 }, { secret: 'wrong-secret' });
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(res.status, 401);
});

test('token using an unsupported algorithm returns 401', async () => {
  const token = sign({ sub: 1, role: 'ADMIN', tv: 0 }, { algorithm: 'HS384' });
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(res.status, 401);
});

test('token for a nonexistent user returns 401', async () => {
  const token = sign({ sub: 999999, role: 'ADMIN', tv: 0 });
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(res.status, 401);
});

test('disabled account returns 403 ACCOUNT_DISABLED', async () => {
  const token = await loginAdmin();
  await auth.pool.query('UPDATE users SET is_active = 0 WHERE phone = ?', [STAFF_PHONE]);
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'ACCOUNT_DISABLED');
});

test('stale token-version claim returns 401', async () => {
  const token = await loginAdmin();
  await auth.pool.query(
    'UPDATE users SET token_version = token_version + 1 WHERE phone = ?',
    [STAFF_PHONE]
  );
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});
