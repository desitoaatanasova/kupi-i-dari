'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const VOL_PHONE = '+359883000001';
const STAFF_PHONE = '+359883000002';
const SAFE_KEYS = [
  'id',
  'phone',
  'firstName',
  'lastName',
  'role',
  'isActive',
  'mustChangePassword',
];

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

function register(body) {
  return auth.postJson(server.baseUrl, '/api/auth/register', body);
}

function volunteerBody(overrides = {}) {
  return {
    firstName: 'Мария',
    lastName: 'Иванова',
    phone: VOL_PHONE,
    role: 'VOLUNTEER',
    ...overrides,
  };
}

test('registers a volunteer and returns a real token response', async () => {
  const res = await register(volunteerBody());

  assert.equal(res.status, 201);
  assert.equal(res.body.tokenType, 'Bearer');
  assert.equal(typeof res.body.token, 'string');
  assert.equal(typeof res.body.expiresIn, 'number');
  assert.deepEqual(Object.keys(res.body.user).sort(), [...SAFE_KEYS].sort());
  assert.equal(res.body.user.phone, VOL_PHONE);
  assert.equal(res.body.user.firstName, 'Мария');
  assert.equal(res.body.user.lastName, 'Иванова');
  assert.equal(res.body.user.role, 'VOLUNTEER');
  assert.equal(res.body.user.isActive, true);
  assert.equal(res.body.user.mustChangePassword, false);
  assert.equal(res.body.user.password_hash, undefined);
  assert.equal(res.body.user.tokenVersion, undefined);
});

test('registered volunteer is stored without a password', async () => {
  const res = await register(volunteerBody({ phone: '0883000001' }));
  assert.equal(res.status, 201);

  const [rows] = await auth.pool.query(
    'SELECT role, password_hash, is_active, created_by FROM users WHERE phone = ?',
    [VOL_PHONE]
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0].role, 'VOLUNTEER');
  assert.equal(rows[0].password_hash, null);
  assert.equal(rows[0].is_active, 1);
  assert.equal(rows[0].created_by, null);
});

test('registration token authenticates against /me', async () => {
  const res = await register(volunteerBody());
  const me = await auth.getJson(server.baseUrl, '/api/auth/me', res.body.token);

  assert.equal(me.status, 200);
  assert.equal(me.body.id, res.body.user.id);
  assert.equal(me.body.role, 'VOLUNTEER');
  assert.equal(me.body.phone, VOL_PHONE);
});

test('public registration rejects privileged roles', async () => {
  for (const role of ['ADMIN', 'RESPONSIBLE', undefined, 'STAFF', 'volunteer', null]) {
    const res = await register(volunteerBody({ role }));
    assert.equal(res.status, 400, String(role));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }

  const [rows] = await auth.pool.query('SELECT COUNT(*) AS total FROM users');
  assert.equal(Number(rows[0].total), 0);
});

test('registration validates names, phone and unknown fields', async () => {
  const bodies = [
    {},
    volunteerBody({ firstName: '' }),
    volunteerBody({ lastName: '' }),
    volunteerBody({ firstName: 'А'.repeat(61) }),
    volunteerBody({ lastName: 'Б'.repeat(61) }),
    volunteerBody({ firstName: 1 }),
    volunteerBody({ phone: 'bad' }),
    volunteerBody({ phone: 123 }),
    { ...volunteerBody(), extra: true },
  ];

  for (const body of bodies) {
    const res = await register(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }

  const [rows] = await auth.pool.query('SELECT COUNT(*) AS total FROM users');
  assert.equal(Number(rows[0].total), 0);
});

test('duplicate volunteer phone returns PHONE_TAKEN', async () => {
  const first = await register(volunteerBody());
  const second = await register(volunteerBody({ firstName: 'Друга' }));

  assert.equal(first.status, 201);
  assert.equal(second.status, 409);
  assert.equal(second.body.error.code, 'PHONE_TAKEN');

  const [rows] = await auth.pool.query(
    'SELECT COUNT(*) AS total FROM users WHERE phone = ?',
    [VOL_PHONE]
  );
  assert.equal(Number(rows[0].total), 1);
});

test('registration cannot take a phone used by a staff account', async () => {
  await auth.createUser({
    phone: STAFF_PHONE,
    firstName: 'Служител',
    lastName: 'Тестов',
    role: 'ADMIN',
    password: auth.TEST_PASSWORD,
  });

  const res = await register(volunteerBody({ phone: STAFF_PHONE }));
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'PHONE_TAKEN');

  const [rows] = await auth.pool.query(
    'SELECT role, password_hash FROM users WHERE phone = ?',
    [STAFF_PHONE]
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0].role, 'ADMIN');
  assert.notEqual(rows[0].password_hash, null);
});

test('concurrent registrations create exactly one account', async () => {
  const body = volunteerBody({ firstName: 'Паралелен', lastName: 'Тест' });
  const results = await Promise.all([
    register(body),
    register(body),
    register(body),
    register(body),
    register(body),
  ]);

  const created = results.filter((res) => res.status === 201);
  const rejected = results.filter((res) => res.status === 409);
  assert.equal(created.length, 1);
  assert.equal(rejected.length, 4);
  for (const res of rejected) {
    assert.equal(res.body.error.code, 'PHONE_TAKEN');
  }

  const ids = new Set(created.map((res) => res.body.user.id));
  assert.equal(ids.size, 1);

  const [rows] = await auth.pool.query(
    'SELECT COUNT(*) AS total FROM users WHERE phone = ?',
    [VOL_PHONE]
  );
  assert.equal(Number(rows[0].total), 1);
});
