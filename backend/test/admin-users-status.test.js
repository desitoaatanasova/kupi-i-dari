'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const users = require('../src/services/users');
const app = require('../src/app');

const SAFE_KEYS = ['id', 'phone', 'firstName', 'lastName', 'role', 'isActive', 'mustChangePassword'];
const BASE = 881300000;

let server;
let adminToken;
let adminId;

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
  ({ token: adminToken, id: adminId } = await auth.createAdminToken(server.baseUrl));
});

function phone(n) {
  return `+359${BASE + n}`;
}

function setStatus(userId, isActive, token = adminToken) {
  return auth.patchJson(
    server.baseUrl,
    `/api/admin/users/${userId}/status`,
    { isActive },
    token
  );
}

async function loginStaff(phoneNumber) {
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: phoneNumber,
    password: auth.TEST_PASSWORD,
  });
  return res.body.token;
}

async function isActiveInDb(userId) {
  const [rows] = await auth.pool.query('SELECT is_active FROM users WHERE user_id = ?', [userId]);
  return Boolean(rows[0].is_active);
}

test('status change requires authentication', async () => {
  const res = await setStatus(adminId, false, null);
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('status change forbids non-admin staff', async () => {
  const id = await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(1));
  const res = await setStatus(id, false, token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('deactivates and reactivates a responsible user', async () => {
  const userId = await auth.createUser({
    phone: phone(1),
    role: 'RESPONSIBLE',
    password: auth.TEST_PASSWORD,
  });

  const deactivated = await setStatus(userId, false);
  assert.equal(deactivated.status, 200);
  assert.equal(deactivated.body.isActive, false);
  assert.deepEqual(Object.keys(deactivated.body).sort(), [...SAFE_KEYS].sort());

  const reactivated = await setStatus(userId, true);
  assert.equal(reactivated.status, 200);
  assert.equal(reactivated.body.isActive, true);
});

test('deactivates an admin while another active admin remains', async () => {
  const other = await auth.createUser({ phone: phone(2), role: 'ADMIN', password: auth.TEST_PASSWORD });
  const res = await setStatus(other, false);
  assert.equal(res.status, 200);
  assert.equal(res.body.isActive, false);
});

test('an administrator cannot deactivate their own account', async () => {
  const res = await setStatus(adminId, false);
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'SELF_DEACTIVATION');
  assert.equal(await isActiveInDb(adminId), true);
});

test('the last active administrator cannot be deactivated', async () => {
  await assert.rejects(
    users.setActiveStatus(adminId, false, adminId + 9999),
    (error) => error && error.code === 'LAST_ADMIN' && error.status === 409
  );
  assert.equal(await isActiveInDb(adminId), true);
});

test('status changes are idempotent', async () => {
  const id = await auth.createUser({ phone: phone(3), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const first = await setStatus(id, false);
  assert.equal(first.status, 200);
  assert.equal(first.body.isActive, false);

  const second = await setStatus(id, false);
  assert.equal(second.status, 200);
  assert.equal(second.body.isActive, false);
  assert.equal(await isActiveInDb(id), false);

  const active = await setStatus(id, true);
  assert.equal(active.status, 200);
  assert.equal(active.body.isActive, true);
});

test('status change on a missing user returns 404', async () => {
  const res = await setStatus(99999999, false);
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});

test('rejects malformed user ids on status change', async () => {
  for (const id of ['abc', '0', '1.5']) {
    const res = await setStatus(id, false);
    assert.equal(res.status, 400, id);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', id);
  }
});

test('rejects invalid status payloads', async () => {
  const bodies = [{}, { isActive: 'yes' }, { isActive: 1 }, { extra: true, isActive: true }];
  for (const body of bodies) {
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/admin/users/${adminId}/status`,
      body,
      adminToken
    );
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('concurrent deactivations never remove every active administrator', async () => {
  await auth.pool.query('UPDATE users SET is_active = 0 WHERE user_id = ?', [adminId]);
  const a = await auth.createAdminToken(server.baseUrl, { phone: phone(30) });
  const b = await auth.createAdminToken(server.baseUrl, { phone: phone(31) });

  const results = await Promise.all([
    setStatus(b.id, false, a.token),
    setStatus(a.id, false, b.token),
  ]);

  const successCount = results.filter((res) => res.status === 200).length;
  assert.ok(successCount <= 1, 'both concurrent deactivations must not succeed');

  const [rows] = await auth.pool.query(
    "SELECT COUNT(*) AS total FROM users WHERE role = 'ADMIN' AND is_active = 1"
  );
  assert.ok(Number(rows[0].total) >= 1, 'at least one active administrator must remain');
});
