'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SAFE_KEYS = ['id', 'phone', 'firstName', 'lastName', 'role', 'isActive', 'mustChangePassword'];
const BASE = 881100000;

let server;
let adminToken;

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
  ({ token: adminToken } = await auth.createAdminToken(server.baseUrl));
});

function phone(n) {
  return `+359${BASE + n}`;
}

function seed(n, role, isActive = true) {
  return auth.createUser({
    phone: phone(n),
    firstName: `Име${n}`,
    lastName: 'Тестов',
    role,
    password: auth.TEST_PASSWORD,
    isActive,
  });
}

test('listing requires authentication', async () => {
  const res = await auth.getJson(server.baseUrl, '/api/admin/users');
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('listing forbids non-admin staff', async () => {
  await seed(1, 'RESPONSIBLE');
  const login = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: phone(1),
    password: auth.TEST_PASSWORD,
  });
  const res = await auth.getJson(server.baseUrl, '/api/admin/users', login.body.token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('returns paginated users with metadata', async () => {
  await seed(1, 'VOLUNTEER');
  await seed(2, 'RESPONSIBLE');
  await seed(3, 'ADMIN');

  const res = await auth.getJson(server.baseUrl, '/api/admin/users', adminToken);
  assert.equal(res.status, 200);
  assert.equal(res.body.pagination.page, 1);
  assert.equal(res.body.pagination.pageSize, 20);
  assert.equal(res.body.pagination.total, 4);
  assert.equal(res.body.pagination.totalPages, 1);
  assert.equal(res.body.users.length, 4);
});

test('orders results by id ascending', async () => {
  const first = await seed(1, 'VOLUNTEER');
  const second = await seed(2, 'VOLUNTEER');

  const res = await auth.getJson(server.baseUrl, '/api/admin/users', adminToken);
  const ids = res.body.users.map((user) => user.id);
  assert.deepEqual(ids, [...ids].sort((a, b) => a - b));
  assert.ok(ids.indexOf(first) < ids.indexOf(second));
});

test('filters by role', async () => {
  await seed(1, 'VOLUNTEER');
  await seed(2, 'RESPONSIBLE');

  const res = await auth.getJson(server.baseUrl, '/api/admin/users?role=RESPONSIBLE', adminToken);
  assert.equal(res.body.pagination.total, 1);
  assert.equal(res.body.users.length, 1);
  assert.equal(res.body.users[0].role, 'RESPONSIBLE');
});

test('filters by active status and keeps the count in sync', async () => {
  const inactiveId = await seed(1, 'VOLUNTEER', false);
  await seed(2, 'VOLUNTEER', true);

  const res = await auth.getJson(server.baseUrl, '/api/admin/users?isActive=false', adminToken);
  assert.equal(res.body.pagination.total, 1);
  assert.equal(res.body.users.length, 1);
  assert.equal(res.body.users[0].id, inactiveId);
  assert.equal(res.body.users[0].isActive, false);
});

test('applies page and pageSize windows', async () => {
  for (let i = 1; i <= 5; i += 1) await seed(i, 'VOLUNTEER');

  const res = await auth.getJson(
    server.baseUrl,
    '/api/admin/users?page=2&pageSize=2',
    adminToken
  );
  assert.equal(res.body.users.length, 2);
  assert.equal(res.body.pagination.page, 2);
  assert.equal(res.body.pagination.pageSize, 2);
  assert.equal(res.body.pagination.total, 6);
  assert.equal(res.body.pagination.totalPages, 3);
});

test('rejects invalid, duplicated and unsupported query parameters', async () => {
  const paths = [
    '/api/admin/users?role=SUPER',
    '/api/admin/users?isActive=maybe',
    '/api/admin/users?page=0',
    '/api/admin/users?page=abc',
    '/api/admin/users?page=-1',
    '/api/admin/users?page=1.5',
    '/api/admin/users?pageSize=0',
    '/api/admin/users?pageSize=101',
    '/api/admin/users?unknown=1',
    '/api/admin/users?role=ADMIN&role=RESPONSIBLE',
  ];

  for (const path of paths) {
    const res = await auth.getJson(server.baseUrl, path, adminToken);
    assert.equal(res.status, 400, path);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', path);
  }
});

test('never leaks internal security fields', async () => {
  await seed(1, 'RESPONSIBLE');
  const res = await auth.getJson(server.baseUrl, '/api/admin/users', adminToken);
  for (const user of res.body.users) {
    assert.deepEqual(Object.keys(user).sort(), [...SAFE_KEYS].sort());
  }
});
