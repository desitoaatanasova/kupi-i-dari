'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const VOL_PHONE = '+359882000001';
const STAFF_PHONE = '+359882000002';

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

function identify(body) {
  return auth.postJson(server.baseUrl, '/api/auth/volunteer', body);
}

test('first-time volunteer creation returns a token and VOLUNTEER profile', async () => {
  const res = await identify({
    firstName: 'Мария',
    lastName: 'Иванова',
    phone: VOL_PHONE,
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.tokenType, 'Bearer');
  assert.equal(typeof res.body.token, 'string');
  assert.equal(res.body.user.role, 'VOLUNTEER');
  assert.equal(res.body.user.firstName, 'Мария');
  assert.equal(res.body.user.phone, VOL_PHONE);

  const [rows] = await auth.pool.query(
    'SELECT role, password_hash FROM users WHERE phone = ?',
    [VOL_PHONE]
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0].role, 'VOLUNTEER');
  assert.equal(rows[0].password_hash, null);
});

test('returning volunteer with matching name succeeds', async () => {
  const first = await identify({ firstName: 'Мария', lastName: 'Иванова', phone: VOL_PHONE });
  const second = await identify({ firstName: 'Мария', lastName: 'Иванова', phone: VOL_PHONE });
  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(first.body.user.id, second.body.user.id);
});

test('name matching is case-insensitive and whitespace-insensitive', async () => {
  await identify({ firstName: 'Мария', lastName: 'Иванова', phone: VOL_PHONE });
  const res = await identify({ firstName: '  МАРИЯ ', lastName: 'иванова', phone: '0882000001' });
  assert.equal(res.status, 200);
});

test('name mismatch returns generic 401', async () => {
  await identify({ firstName: 'Мария', lastName: 'Иванова', phone: VOL_PHONE });
  const res = await identify({ firstName: 'Друго', lastName: 'Име', phone: VOL_PHONE });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('staff phone cannot use the volunteer endpoint', async () => {
  await auth.createUser({
    phone: STAFF_PHONE,
    firstName: 'Служител',
    lastName: 'Тестов',
    role: 'ADMIN',
    password: auth.TEST_PASSWORD,
  });
  const res = await identify({ firstName: 'Служител', lastName: 'Тестов', phone: STAFF_PHONE });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('invalid bodies and unknown fields return 400', async () => {
  for (const body of [
    {},
    { firstName: 'А', lastName: 'Б' },
    { firstName: '', lastName: 'Б', phone: VOL_PHONE },
    { firstName: 'А', lastName: 'Б', phone: 'bad' },
    { firstName: 1, lastName: 'Б', phone: VOL_PHONE },
    { firstName: 'А', lastName: 'Б', phone: VOL_PHONE, role: 'ADMIN' },
  ]) {
    const res = await identify(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});

test('volunteer endpoint never creates privileged accounts', async () => {
  await identify({ firstName: 'А', lastName: 'Б', phone: VOL_PHONE });
  const [rows] = await auth.pool.query('SELECT role FROM users WHERE phone = ?', [VOL_PHONE]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].role, 'VOLUNTEER');
});

test('concurrent first-time requests do not create duplicates', async () => {
  const body = { firstName: 'Паралелен', lastName: 'Тест', phone: VOL_PHONE };
  const results = await Promise.all([
    identify(body),
    identify(body),
    identify(body),
    identify(body),
    identify(body),
  ]);

  for (const res of results) {
    assert.equal(res.status, 200);
    assert.equal(res.body.user.role, 'VOLUNTEER');
  }
  const ids = new Set(results.map((res) => res.body.user.id));
  assert.equal(ids.size, 1);

  const [rows] = await auth.pool.query('SELECT COUNT(*) AS c FROM users WHERE phone = ?', [VOL_PHONE]);
  assert.equal(Number(rows[0].c), 1);
});

test('volunteer token authenticates against /me', async () => {
  const res = await identify({ firstName: 'Мария', lastName: 'Иванова', phone: VOL_PHONE });
  const me = await auth.getJson(server.baseUrl, '/api/auth/me', res.body.token);
  assert.equal(me.status, 200);
  assert.equal(me.body.role, 'VOLUNTEER');
  assert.equal(me.body.id, res.body.user.id);
});
