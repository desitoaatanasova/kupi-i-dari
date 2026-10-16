'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const STAFF_PHONE = '+359883500001';

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

async function seedAdmin() {
  await auth.createUser({
    phone: STAFF_PHONE,
    firstName: 'Админ',
    lastName: 'Тестов',
    role: 'ADMIN',
    password: auth.TEST_PASSWORD,
  });
}

async function login() {
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: STAFF_PHONE,
    password: auth.TEST_PASSWORD,
  });
  assert.equal(res.status, 200);
  return res.body.token;
}

test('logout returns 204 with no body and invalidates the token', async () => {
  await seedAdmin();
  const token = await login();
  assert.equal((await auth.getJson(server.baseUrl, '/api/auth/me', token)).status, 200);

  const res = await auth.request(server.baseUrl, 'POST', '/api/auth/logout', { token });
  assert.equal(res.status, 204);
  assert.equal(res.body, null);

  const afterRes = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(afterRes.status, 401);
  assert.equal(afterRes.body.error.code, 'UNAUTHORIZED');
});

test('all tokens issued before logout are invalidated', async () => {
  await seedAdmin();
  const tokenA = await login();
  const tokenB = await login();

  const logout = await auth.request(server.baseUrl, 'POST', '/api/auth/logout', { token: tokenA });
  assert.equal(logout.status, 204);

  assert.equal((await auth.getJson(server.baseUrl, '/api/auth/me', tokenA)).status, 401);
  assert.equal((await auth.getJson(server.baseUrl, '/api/auth/me', tokenB)).status, 401);
});

test('missing or invalid token is rejected on logout', async () => {
  await seedAdmin();
  const missing = await auth.request(server.baseUrl, 'POST', '/api/auth/logout', {});
  assert.equal(missing.status, 401);
  assert.equal(missing.body.error.code, 'UNAUTHORIZED');

  const invalid = await auth.request(server.baseUrl, 'POST', '/api/auth/logout', {
    token: 'not-a-jwt',
  });
  assert.equal(invalid.status, 401);
  assert.equal(invalid.body.error.code, 'UNAUTHORIZED');
});

test('user can authenticate again and receive a valid new token', async () => {
  await seedAdmin();
  const token = await login();
  await auth.request(server.baseUrl, 'POST', '/api/auth/logout', { token });

  const newToken = await login();
  assert.notEqual(newToken, token);
  const res = await auth.getJson(server.baseUrl, '/api/auth/me', newToken);
  assert.equal(res.status, 200);
  assert.equal(res.body.role, 'ADMIN');
});
