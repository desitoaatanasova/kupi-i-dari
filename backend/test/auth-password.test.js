'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SAFE_KEYS = ['id', 'phone', 'firstName', 'lastName', 'role', 'isActive', 'mustChangePassword'];
const NEW_PASSWORD = 'NewPass456!';

let server;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanQuantities();
  await auth.cleanShifts();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanQuantities();
  await auth.cleanShifts();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
});

// Create a staff account with the forced-password flag set, then log in so the
// token reflects the pending change.
async function seedForcedChangeStaff(role = 'ADMIN', phone = '+359888000001') {
  const id = await auth.createUser({
    phone,
    firstName: 'Служител',
    lastName: 'Тестов',
    role,
    password: auth.TEST_PASSWORD,
  });
  await auth.pool.query('UPDATE users SET must_change_password = 1 WHERE user_id = ?', [id]);
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone,
    password: auth.TEST_PASSWORD,
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.user.mustChangePassword, true);
  return { id, phone, token: res.body.token };
}

test('password change requires authentication', async () => {
  const res = await auth.postJson(server.baseUrl, '/api/auth/password/change', {
    currentPassword: 'OldPass123!',
    newPassword: NEW_PASSWORD,
  });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('validates the request body', async () => {
  const { token } = await auth.createAdminToken(server.baseUrl);
  const bodies = [
    {},
    { currentPassword: 'x' },
    { newPassword: NEW_PASSWORD },
    { currentPassword: '', newPassword: NEW_PASSWORD },
    { currentPassword: 'x', newPassword: '' },
    { currentPassword: 'x', newPassword: 'short' },
    { currentPassword: 'x', newPassword: 'a'.repeat(201) },
    { currentPassword: 123, newPassword: NEW_PASSWORD },
    { currentPassword: 'x', newPassword: NEW_PASSWORD, extra: true },
  ];
  for (const body of bodies) {
    const res = await auth.postJson(server.baseUrl, '/api/auth/password/change', body, token);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('rejects an incorrect current password', async () => {
  const { token } = await auth.createAdminToken(server.baseUrl);
  const res = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: 'WrongPass123!', newPassword: NEW_PASSWORD },
    token
  );
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('rejects a new password identical to the current one', async () => {
  const { token } = await auth.createAdminToken(server.baseUrl);
  const res = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: auth.TEST_PASSWORD, newPassword: auth.TEST_PASSWORD },
    token
  );
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('a volunteer without a password hash cannot set a password', async () => {
  const { token } = await auth.createVolunteerToken(server.baseUrl);
  const res = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: 'anything', newPassword: NEW_PASSWORD },
    token
  );
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'INVALID_CREDENTIALS');
});

test('a successful change returns a fresh token and clears the flag', async () => {
  const { token } = await auth.createAdminToken(server.baseUrl);
  const res = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: auth.TEST_PASSWORD, newPassword: NEW_PASSWORD },
    token
  );

  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(
    Object.keys(res.body).sort(),
    ['expiresIn', 'token', 'tokenType', 'user'].sort()
  );
  assert.equal(res.body.tokenType, 'Bearer');
  assert.equal(typeof res.body.token, 'string');
  assert.equal(typeof res.body.expiresIn, 'number');
  assert.deepEqual(Object.keys(res.body.user).sort(), [...SAFE_KEYS].sort());
  assert.equal(res.body.user.mustChangePassword, false);

  const me = await auth.getJson(server.baseUrl, '/api/auth/me', res.body.token);
  assert.equal(me.status, 200);
  assert.equal(me.body.mustChangePassword, false);
});

test('a forced-change staff member still gets a valid token on login', async () => {
  const { token } = await seedForcedChangeStaff();
  const me = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(me.status, 200);
  assert.equal(me.body.mustChangePassword, true);
});

test('blocks every protected route until the password is changed', async () => {
  const { token } = await seedForcedChangeStaff('ADMIN');
  const protectedRoutes = [
    ['/api/admin/users', 'GET'],
    ['/api/quantities', 'GET'],
    ['/api/shifts', 'GET'],
    ['/api/reports/collected', 'GET'],
    ['/api/reports/inventory', 'GET'],
  ];
  for (const [path, method] of protectedRoutes) {
    const res = await auth.request(server.baseUrl, method, path, { token });
    assert.equal(res.status, 403, `${method} ${path}`);
    assert.equal(res.body.error.code, 'MUST_CHANGE_PASSWORD', `${method} ${path}`);
    assert.equal(
      res.body.error.message,
      'Password change is required before continuing.',
      `${method} ${path}`
    );
  }
});

test('public routes stay reachable while a password change is pending', async () => {
  const { token } = await seedForcedChangeStaff('ADMIN');
  const locations = await auth.getJson(server.baseUrl, '/api/locations', token);
  assert.equal(locations.status, 200);
  const products = await auth.getJson(server.baseUrl, '/api/products', token);
  assert.equal(products.status, 200);
});

test('after changing the password the protected routes unlock', async () => {
  const { token } = await seedForcedChangeStaff('ADMIN');
  const change = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: auth.TEST_PASSWORD, newPassword: NEW_PASSWORD },
    token
  );
  assert.equal(change.status, 200);

  const res = await auth.getJson(server.baseUrl, '/api/quantities', change.body.token);
  assert.equal(res.status, 200);
});

test('staff pending a change can log out', async () => {
  const { token } = await seedForcedChangeStaff('RESPONSIBLE');
  const res = await auth.postJson(server.baseUrl, '/api/auth/logout', undefined, token);
  assert.equal(res.status, 204);
});

test('the old token and old password stop working after the change', async () => {
  const { token, phone } = await auth.createAdminToken(server.baseUrl);
  const change = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: auth.TEST_PASSWORD, newPassword: NEW_PASSWORD },
    token
  );
  assert.equal(change.status, 200);

  const stale = await auth.getJson(server.baseUrl, '/api/auth/me', token);
  assert.equal(stale.status, 401);
  assert.equal(stale.body.error.code, 'UNAUTHORIZED');

  const oldLogin = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone,
    password: auth.TEST_PASSWORD,
  });
  assert.equal(oldLogin.status, 401);
  assert.equal(oldLogin.body.error.code, 'INVALID_CREDENTIALS');

  const newLogin = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone,
    password: NEW_PASSWORD,
  });
  assert.equal(newLogin.status, 200);
  assert.equal(newLogin.body.user.mustChangePassword, false);
});

test('staff without the flag are unaffected', async () => {
  const { token } = await auth.createResponsibleToken(server.baseUrl);
  const res = await auth.getJson(server.baseUrl, '/api/quantities', token);
  assert.equal(res.status, 200);
});

test('the change response never leaks internal fields', async () => {
  const { token } = await auth.createAdminToken(server.baseUrl);
  const res = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: auth.TEST_PASSWORD, newPassword: NEW_PASSWORD },
    token
  );
  assert.equal(res.status, 200);

  const text = JSON.stringify(res.body);
  for (const key of [
    'passwordHash',
    'password_hash',
    'tokenVersion',
    'token_version',
    'must_change_password',
    'last_login_at',
    'createdAt',
    'updatedAt',
  ]) {
    assert.ok(!text.includes(key), key);
  }
});

test('a disabled account cannot change its password', async () => {
  const { id, token } = await auth.createAdminToken(server.baseUrl);
  await auth.pool.query('UPDATE users SET is_active = 0 WHERE user_id = ?', [id]);
  const res = await auth.postJson(
    server.baseUrl,
    '/api/auth/password/change',
    { currentPassword: auth.TEST_PASSWORD, newPassword: NEW_PASSWORD },
    token
  );
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'ACCOUNT_DISABLED');
});
