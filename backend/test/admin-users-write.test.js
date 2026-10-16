'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SAFE_KEYS = ['id', 'phone', 'firstName', 'lastName', 'role', 'isActive', 'mustChangePassword'];
const BASE = 881200000;

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

function newStaff(overrides = {}) {
  return {
    firstName: 'Нов',
    lastName: 'Служител',
    phone: phone(1),
    role: 'RESPONSIBLE',
    password: 'StrongPass1',
    ...overrides,
  };
}

function postStaff(body, token = adminToken) {
  return auth.postJson(server.baseUrl, '/api/admin/users', body, token);
}

async function loginStaff(phoneNumber) {
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: phoneNumber,
    password: auth.TEST_PASSWORD,
  });
  return res.body.token;
}

test('creation requires authentication', async () => {
  const res = await postStaff(newStaff(), null);
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('creation forbids non-admin staff', async () => {
  await auth.createUser({ phone: phone(9), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(9));
  const res = await postStaff(newStaff(), token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('creates RESPONSIBLE and ADMIN accounts with a safe profile', async () => {
  const responsible = await postStaff(newStaff());
  assert.equal(responsible.status, 201);
  assert.equal(responsible.body.role, 'RESPONSIBLE');
  assert.equal(responsible.body.isActive, true);
  assert.equal(responsible.body.mustChangePassword, true);
  assert.deepEqual(Object.keys(responsible.body).sort(), [...SAFE_KEYS].sort());

  const admin = await postStaff(newStaff({ phone: phone(2), role: 'ADMIN' }));
  assert.equal(admin.status, 201);
  assert.equal(admin.body.role, 'ADMIN');
});

test('records the acting administrator in created_by', async () => {
  const res = await postStaff(newStaff());
  const [rows] = await auth.pool.query(
    'SELECT created_by FROM users WHERE user_id = ?',
    [res.body.id]
  );
  assert.equal(rows[0].created_by, adminId);
});

test('does not create VOLUNTEER accounts here', async () => {
  const res = await postStaff(newStaff({ role: 'VOLUNTEER' }));
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('enforces password length boundaries without trimming', async () => {
  const tooShort = await postStaff(newStaff({ password: '1234567' }));
  assert.equal(tooShort.status, 400);
  assert.equal(tooShort.body.error.code, 'VALIDATION_ERROR');

  const tooLong = await postStaff(newStaff({ password: 'a'.repeat(201) }));
  assert.equal(tooLong.status, 400);
});

test('does not trim the password before hashing', async () => {
  const raw = '  secret12  ';
  const res = await postStaff(newStaff({ password: raw }));
  assert.equal(res.status, 201);

  const [rows] = await auth.pool.query(
    'SELECT password_hash FROM users WHERE user_id = ?',
    [res.body.id]
  );
  assert.equal(await bcrypt.compare(raw, rows[0].password_hash), true);
  assert.equal(await bcrypt.compare(raw.trim(), rows[0].password_hash), false);
});

test('rejects duplicate normalized phone with 409', async () => {
  const first = await postStaff(newStaff({ phone: '0881200001' }));
  assert.equal(first.status, 201);

  const duplicate = await postStaff(newStaff({ phone: '+359881200001' }));
  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.body.error.code, 'PHONE_TAKEN');
});

test('rejects invalid creation payloads', async () => {
  const cases = [
    newStaff({ role: 'SUPER' }),
    newStaff({ phone: 'not-a-phone' }),
    newStaff({ firstName: '' }),
    newStaff({ lastName: 'A'.repeat(61) }),
    { ...newStaff(), extra: 'x' },
    { firstName: 'И', lastName: 'С', phone: phone(3), role: 'ADMIN' },
  ];

  for (const body of cases) {
    const res = await postStaff(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('creation response never exposes the password or hash', async () => {
  const res = await postStaff(newStaff());
  assert.deepEqual(Object.keys(res.body).sort(), [...SAFE_KEYS].sort());
  const text = JSON.stringify(res.body);
  assert.ok(!text.includes('password'));
  assert.ok(!text.includes('hash'));
});

test('reads a single user by id', async () => {
  const created = await postStaff(newStaff());
  const res = await auth.getJson(
    server.baseUrl,
    `/api/admin/users/${created.body.id}`,
    adminToken
  );
  assert.equal(res.status, 200);
  assert.equal(res.body.id, created.body.id);
  assert.deepEqual(Object.keys(res.body).sort(), [...SAFE_KEYS].sort());
});

test('reading a missing user returns 404', async () => {
  const res = await auth.getJson(server.baseUrl, '/api/admin/users/99999999', adminToken);
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});

test('rejects malformed user ids on read', async () => {
  for (const id of ['abc', '-1', '1.5', '0']) {
    const res = await auth.getJson(server.baseUrl, `/api/admin/users/${id}`, adminToken);
    assert.equal(res.status, 400, id);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', id);
  }
});

test('profile update requires authentication', async () => {
  const created = await postStaff(newStaff());
  const res = await auth.patchJson(
    server.baseUrl,
    `/api/admin/users/${created.body.id}`,
    { firstName: 'X' }
  );
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('updates permitted fields and leaves others unchanged', async () => {
  const created = await postStaff(
    newStaff({ firstName: 'Старо', lastName: 'Име', phone: phone(1) })
  );

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/admin/users/${created.body.id}`,
    { firstName: 'Ново' },
    adminToken
  );

  assert.equal(res.status, 200);
  assert.equal(res.body.firstName, 'Ново');
  assert.equal(res.body.lastName, 'Име');
  assert.equal(res.body.phone, phone(1));
  assert.equal(res.body.role, 'RESPONSIBLE');
  assert.equal(res.body.mustChangePassword, true);
  assert.deepEqual(Object.keys(res.body).sort(), [...SAFE_KEYS].sort());
});

test('normalizes an updated phone number', async () => {
  const created = await postStaff(newStaff());
  const res = await auth.patchJson(
    server.baseUrl,
    `/api/admin/users/${created.body.id}`,
    { phone: '0881 200 099' },
    adminToken
  );
  assert.equal(res.status, 200);
  assert.equal(res.body.phone, '+359881200099');
});

test('rejects duplicate phone on update with 409', async () => {
  await postStaff(newStaff({ phone: phone(1) }));
  const second = await postStaff(newStaff({ phone: phone(2) }));

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/admin/users/${second.body.id}`,
    { phone: phone(1) },
    adminToken
  );
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'PHONE_TAKEN');
});

test('rejects role and security-field changes', async () => {
  const created = await postStaff(newStaff());
  const bodies = [
    { role: 'ADMIN' },
    { password: 'x'.repeat(10) },
    { isActive: false },
    { mustChangePassword: false },
    { tokenVersion: 0 },
    { createdBy: 1 },
  ];

  for (const body of bodies) {
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/admin/users/${created.body.id}`,
      body,
      adminToken
    );
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('rejects an empty update body', async () => {
  const created = await postStaff(newStaff());
  const res = await auth.patchJson(
    server.baseUrl,
    `/api/admin/users/${created.body.id}`,
    {},
    adminToken
  );
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('updating a missing user returns 404', async () => {
  const res = await auth.patchJson(
    server.baseUrl,
    '/api/admin/users/99999999',
    { firstName: 'X' },
    adminToken
  );
  assert.equal(res.status, 404);
});

test('rejects a malformed user id on update', async () => {
  const res = await auth.patchJson(
    server.baseUrl,
    '/api/admin/users/abc',
    { firstName: 'X' },
    adminToken
  );
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('profile update forbids non-admin staff', async () => {
  const created = await postStaff(newStaff());
  await auth.createUser({ phone: phone(8), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(8));

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/admin/users/${created.body.id}`,
    { firstName: 'X' },
    token
  );
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});
