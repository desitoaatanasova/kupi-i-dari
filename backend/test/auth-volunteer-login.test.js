'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const VOL_PHONE = '+359883100001';
const STAFF_PHONE = '+359883100002';

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

function login(body) {
  return auth.postJson(server.baseUrl, '/api/auth/volunteer/login', body);
}

function credentials(overrides = {}) {
  return {
    firstName: 'Мария',
    lastName: 'Иванова',
    phone: VOL_PHONE,
    ...overrides,
  };
}

async function seedVolunteer({ isActive = true } = {}) {
  return auth.createUser({
    phone: VOL_PHONE,
    firstName: 'Мария',
    lastName: 'Иванова',
    role: 'VOLUNTEER',
    isActive,
  });
}

test('existing active volunteer signs in without a password', async () => {
  await seedVolunteer();
  const res = await login(credentials());

  assert.equal(res.status, 200);
  assert.equal(res.body.tokenType, 'Bearer');
  assert.equal(typeof res.body.token, 'string');
  assert.equal(res.body.user.phone, VOL_PHONE);
  assert.equal(res.body.user.role, 'VOLUNTEER');
  assert.equal(res.body.user.password_hash, undefined);
});

test('name matching is case-insensitive and whitespace-insensitive', async () => {
  await seedVolunteer();
  const res = await login({
    firstName: '  МАРИЯ ',
    lastName: 'иванова',
    phone: '0883100001',
  });

  assert.equal(res.status, 200);
});

test('volunteer login token authenticates against /me', async () => {
  await seedVolunteer();
  const res = await login(credentials());
  const me = await auth.getJson(server.baseUrl, '/api/auth/me', res.body.token);

  assert.equal(me.status, 200);
  assert.equal(me.body.id, res.body.user.id);
  assert.equal(me.body.role, 'VOLUNTEER');
});

test('unknown phone returns generic 401 and creates no account', async () => {
  const res = await login(credentials());

  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');

  const [rows] = await auth.pool.query('SELECT COUNT(*) AS total FROM users');
  assert.equal(Number(rows[0].total), 0);
});

test('wrong name returns generic 401', async () => {
  await seedVolunteer();
  const res = await login(credentials({ firstName: 'Друга' }));

  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('staff phone cannot use volunteer login', async () => {
  await auth.createUser({
    phone: STAFF_PHONE,
    firstName: 'Мария',
    lastName: 'Иванова',
    role: 'ADMIN',
    password: auth.TEST_PASSWORD,
  });
  const res = await login(credentials({ phone: STAFF_PHONE }));

  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('inactive volunteer is rejected with ACCOUNT_DISABLED', async () => {
  await seedVolunteer({ isActive: false });
  const res = await login(credentials());

  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'ACCOUNT_DISABLED');
});

test('invalid bodies and unknown fields return 400', async () => {
  const bodies = [
    {},
    credentials({ firstName: '' }),
    credentials({ lastName: '' }),
    credentials({ phone: '' }),
    credentials({ phone: 'bad' }),
    credentials({ phone: 123 }),
    { ...credentials(), password: 'secret' },
    { ...credentials(), role: 'VOLUNTEER' },
  ];

  for (const body of bodies) {
    const res = await login(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});
