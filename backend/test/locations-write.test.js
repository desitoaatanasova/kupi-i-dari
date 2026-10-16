'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SAFE_KEYS = ['id', 'name', 'address', 'isActive'];
const BASE = 882100000;

let server;
let adminToken;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanLocations();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanLocations();
  await auth.cleanUsers();
  ({ token: adminToken } = await auth.createAdminToken(server.baseUrl));
});

function phone(n) {
  return `+359${BASE + n}`;
}

async function loginStaff(phoneNumber) {
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone: phoneNumber,
    password: auth.TEST_PASSWORD,
  });
  return res.body.token;
}

const create = (body, token = adminToken) =>
  auth.postJson(server.baseUrl, '/api/locations', body, token);

function newLocation(overrides = {}) {
  return { name: 'Нов пункт', address: 'ул. Примерна 10', ...overrides };
}

test('create requires authentication', async () => {
  const res = await auth.postJson(server.baseUrl, '/api/locations', {
    name: 'X',
    address: 'Y',
  });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('create forbids non-admin staff', async () => {
  await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(1));
  const res = await auth.postJson(server.baseUrl, '/api/locations', {
    name: 'Нова точка',
    address: 'ул. Втора 2',
  }, token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('creates a location with a safe object', async () => {
  const res = await auth.postJson(
    server.baseUrl,
    '/api/locations',
    { name: '  Център   Север  ', address: '  ул.  Дунав  3 ' },
    adminToken
  );
  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(res.body).sort(), [...SAFE_KEYS].sort());
  assert.equal(res.body.name, 'Център Север');
  assert.equal(res.body.address, 'ул. Дунав 3');
  assert.equal(res.body.isActive, true);
});

test('rejects invalid creation payloads', async () => {
  const cases = [
    { address: 'ул. Без име 1' },
    { name: 'Без адрес' },
    { name: '', address: 'ул. X 1' },
    { name: 'A'.repeat(121), address: 'ул. X 1' },
    { name: 'Дълъг адрес', address: 'A'.repeat(256) },
    { name: 5, address: 'ул. X 1' },
    { name: 'Име', address: { a: 1 } },
    { name: 'Име', address: 'ул. X 1', extra: 'x' },
    {},
  ];

  for (const body of cases) {
    const res = await auth.postJson(server.baseUrl, '/api/locations', body, adminToken);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('rejects a duplicate name including case variants with 409', async () => {
  const first = await auth.postJson(
    server.baseUrl,
    '/api/locations',
    { name: 'Уникален', address: 'ул. Първа 1' },
    adminToken
  );
  assert.equal(first.status, 201);

  const duplicate = await auth.postJson(
    server.baseUrl,
    '/api/locations',
    { name: 'уникален', address: 'ул. Втора 2' },
    adminToken
  );
  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.body.error.code, 'NAME_TAKEN');
});

test('location writes require authentication', async () => {
  const id = await auth.createLocation({ name: 'Точка', address: 'ул. Основна 1' });
  const update = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}`,
    { name: 'Ново' }
  );
  assert.equal(update.status, 401);

  const status = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}/status`,
    { isActive: false }
  );
  assert.equal(status.status, 401);
});

test('location writes forbid non-admin staff', async () => {
  const id = await auth.createLocation({ name: 'Точка', address: 'ул. Основна 1' });
  await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(1));

  const update = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}`,
    { name: 'Ново' },
    token
  );
  assert.equal(update.status, 403);
  assert.equal(update.body.error.code, 'FORBIDDEN');
});

test('partial update changes only the supplied field', async () => {
  const id = await auth.createLocation({ name: 'Старо име', address: 'ул. Стара 9' });

  const nameOnly = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}`,
    { name: 'Ново име' },
    adminToken
  );
  assert.equal(nameOnly.status, 200);
  assert.equal(nameOnly.body.name, 'Ново име');
  assert.equal(nameOnly.body.address, 'ул. Стара 9');
  assert.deepEqual(Object.keys(nameOnly.body).sort(), [...SAFE_KEYS].sort());

  const addressOnly = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}`,
    { address: 'ул. Нова 10' },
    adminToken
  );
  assert.equal(addressOnly.status, 200);
  assert.equal(addressOnly.body.name, 'Ново име');
  assert.equal(addressOnly.body.address, 'ул. Нова 10');
});

test('rejects empty, unknown, malformed and oversized updates', async () => {
  const id = await auth.createLocation({ name: 'Валидна', address: 'ул. Валидна 1' });
  const cases = [
    { body: {}, path: `/api/locations/${id}` },
    { body: { extra: 'x' }, path: `/api/locations/${id}` },
    { body: { name: '' }, path: `/api/locations/${id}` },
    { body: { name: 'A'.repeat(121) }, path: `/api/locations/${id}` },
    { body: { name: 'Ново' }, path: '/api/locations/abc' },
    { body: { name: 'Ново' }, path: '/api/locations/0' },
  ];

  for (const { body, path } of cases) {
    const res = await auth.patchJson(server.baseUrl, path, body, adminToken);
    assert.equal(res.status, 400, path);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', path);
  }
});

test('updating a missing or archived location returns 404', async () => {
  const archivedId = await auth.createLocation({
    name: 'Архивирана',
    address: 'ул. Стара 1',
    isActive: false,
  });

  const missing = await auth.patchJson(
    server.baseUrl,
    '/api/locations/99999999',
    { name: 'Ново' },
    adminToken
  );
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');

  const archived = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${archivedId}`,
    { name: 'Ново' },
    adminToken
  );
  assert.equal(archived.status, 404);
  assert.equal(archived.body.error.code, 'NOT_FOUND');
});

test('rejects a duplicate name on update with 409', async () => {
  await auth.createLocation({ name: 'Първа', address: 'ул. 1' });
  const secondId = await auth.createLocation({ name: 'Втора', address: 'ул. 2' });

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${secondId}`,
    { name: 'ПЪРВА' },
    adminToken
  );
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'NAME_TAKEN');
});

test('archives and reactivates a location', async () => {
  const id = await auth.createLocation({ name: 'Статус', address: 'ул. Статус 1' });

  const archived = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}/status`,
    { isActive: false },
    adminToken
  );
  assert.equal(archived.status, 200);
  assert.equal(archived.body.isActive, false);
  assert.deepEqual(Object.keys(archived.body).sort(), [...SAFE_KEYS].sort());

  const reactivated = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}/status`,
    { isActive: true },
    adminToken
  );
  assert.equal(reactivated.status, 200);
  assert.equal(reactivated.body.isActive, true);
});

test('repeating a status change is idempotent', async () => {
  const id = await auth.createLocation({ name: 'Идемпотент', address: 'ул. X 1' });

  const first = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}/status`,
    { isActive: false },
    adminToken
  );
  assert.equal(first.status, 200);
  assert.equal(first.body.isActive, false);

  const second = await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}/status`,
    { isActive: false },
    adminToken
  );
  assert.equal(second.status, 200);
  assert.equal(second.body.isActive, false);

  const [rows] = await auth.pool.query(
    'SELECT is_active FROM locations WHERE location_id = ?',
    [id]
  );
  assert.equal(Number(rows[0].is_active), 0);
});

test('rejects malformed ids and invalid status bodies', async () => {
  const id = await auth.createLocation({ name: 'Валидна', address: 'ул. X 1' });

  for (const badId of ['abc', '0', '-1', '1.5']) {
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/locations/${badId}/status`,
      { isActive: false },
      adminToken
    );
    assert.equal(res.status, 400, badId);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', badId);
  }

  const bodyCases = [{}, { isActive: 'yes' }, { isActive: 1 }, { isActive: true, x: 1 }];
  for (const body of bodyCases) {
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/locations/${id}/status`,
      body,
      adminToken
    );
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('status change on a missing location returns 404', async () => {
  const res = await auth.patchJson(
    server.baseUrl,
    '/api/locations/99999999/status',
    { isActive: false },
    adminToken
  );
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});

test('archiving never hard-deletes the row', async () => {
  const id = await auth.createLocation({ name: 'Живее', address: 'ул. X 1' });
  await auth.patchJson(
    server.baseUrl,
    `/api/locations/${id}/status`,
    { isActive: false },
    adminToken
  );

  const [rows] = await auth.pool.query(
    'SELECT location_id FROM locations WHERE location_id = ?',
    [id]
  );
  assert.equal(rows.length, 1);
});
