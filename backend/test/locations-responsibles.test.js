'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SAFE_KEYS = ['id', 'phone', 'firstName', 'lastName', 'role', 'isActive', 'mustChangePassword'];
const BASE = 882200000;

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

function listResponsibles(locationId, token = adminToken) {
  return auth.getJson(server.baseUrl, `/api/locations/${locationId}/responsibles`, token);
}

function setResponsibles(locationId, userIds, token = adminToken) {
  return auth.putJson(
    server.baseUrl,
    `/api/locations/${locationId}/responsibles`,
    { userIds },
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

test('assignment routes require authentication', async () => {
  const id = await auth.createLocation({ name: 'Точка', address: 'ул. X 1' });

  const read = await listResponsibles(id, null);
  assert.equal(read.status, 401);
  assert.equal(read.body.error.code, 'UNAUTHORIZED');

  const write = await setResponsibles(id, [], null);
  assert.equal(write.status, 401);
  assert.equal(write.body.error.code, 'UNAUTHORIZED');
});

test('assignment routes forbid non-admin staff', async () => {
  const id = await auth.createLocation({ name: 'Точка', address: 'ул. X 1' });
  await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(1));

  const read = await listResponsibles(id, token);
  assert.equal(read.status, 403);
  assert.equal(read.body.error.code, 'FORBIDDEN');

  const write = await setResponsibles(id, [], token);
  assert.equal(write.status, 403);
  assert.equal(write.body.error.code, 'FORBIDDEN');
});

test('lists an empty assignment set', async () => {
  const id = await auth.createLocation({ name: 'Празна', address: 'ул. X 1' });
  const res = await listResponsibles(id);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.responsibles, []);
});

test('assigns multiple responsibles and returns the complete sorted set', async () => {
  const id = await auth.createLocation({ name: 'Много', address: 'ул. X 1' });
  const first = await auth.createUser({ phone: phone(1), firstName: 'Първи', role: 'RESPONSIBLE' });
  const second = await auth.createUser({ phone: phone(2), firstName: 'Втори', role: 'RESPONSIBLE' });

  const res = await setResponsibles(id, [second, first]);
  assert.equal(res.status, 200);
  assert.deepEqual(
    res.body.responsibles.map((user) => user.id),
    [first, second]
  );
  for (const user of res.body.responsibles) {
    assert.deepEqual(Object.keys(user).sort(), [...SAFE_KEYS].sort());
  }

  const read = await listResponsibles(id);
  assert.equal(read.status, 200);
  assert.deepEqual(
    read.body.responsibles.map((user) => user.id),
    [first, second]
  );
});

test('one responsible can manage multiple locations', async () => {
  const firstLocation = await auth.createLocation({ name: 'Първа', address: 'ул. X 1' });
  const secondLocation = await auth.createLocation({ name: 'Втора', address: 'ул. Y 2' });
  const userId = await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE' });

  await setResponsibles(firstLocation, [userId]);
  await setResponsibles(secondLocation, [userId]);

  assert.equal((await listResponsibles(firstLocation)).body.responsibles.length, 1);
  assert.equal((await listResponsibles(secondLocation)).body.responsibles.length, 1);
});

test('an empty array clears all assignments', async () => {
  const id = await auth.createLocation({ name: 'Изчисти', address: 'ул. X 1' });
  const userId = await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE' });
  await setResponsibles(id, [userId]);

  const res = await setResponsibles(id, []);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.responsibles, []);

  const read = await listResponsibles(id);
  assert.deepEqual(read.body.responsibles, []);
});

test('rejects volunteers, admins, missing and inactive users', async () => {
  const id = await auth.createLocation({ name: 'Строга', address: 'ул. X 1' });
  const volunteer = await auth.createUser({ phone: phone(1), role: 'VOLUNTEER' });
  const admin = await auth.createUser({
    phone: phone(2),
    role: 'ADMIN',
    password: auth.TEST_PASSWORD,
  });
  const inactive = await auth.createUser({ phone: phone(3), role: 'RESPONSIBLE', isActive: false });

  for (const ids of [[volunteer], [admin], [inactive], [99999999]]) {
    const res = await setResponsibles(id, ids);
    assert.equal(res.status, 400, JSON.stringify(ids));
    assert.equal(res.body.error.code, 'INVALID_RESPONSIBLE', JSON.stringify(ids));
  }
});

test('rejects invalid userIds payloads', async () => {
  const id = await auth.createLocation({ name: 'Валидна', address: 'ул. X 1' });
  const userId = await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE' });

  const cases = [
    { userIds: [userId, userId] },
    { userIds: 'x' },
    { userIds: null },
    { userIds: [0] },
    { userIds: [-1] },
    { userIds: [1.5] },
    { userIds: ['1'] },
    { userIds: [true] },
    { userIds: [], extra: 'x' },
    {},
    { userIds: Array.from({ length: 101 }, (_, i) => userId + i + 1) },
  ];

  for (const body of cases) {
    const res = await auth.putJson(
      server.baseUrl,
      `/api/locations/${id}/responsibles`,
      body,
      adminToken
    );
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('an invalid member leaves the previous assignment set intact', async () => {
  const id = await auth.createLocation({ name: 'Атомична', address: 'ул. X 1' });
  const keptA = await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE' });
  const keptB = await auth.createUser({ phone: phone(2), role: 'RESPONSIBLE' });
  const volunteer = await auth.createUser({ phone: phone(3), role: 'VOLUNTEER' });

  await setResponsibles(id, [keptA, keptB]);

  const res = await setResponsibles(id, [keptA, volunteer]);
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'INVALID_RESPONSIBLE');

  const read = await listResponsibles(id);
  assert.deepEqual(
    read.body.responsibles.map((user) => user.id).sort((a, b) => a - b),
    [keptA, keptB].sort((a, b) => a - b)
  );
});

test('concurrent replacements never merge', async () => {
  const id = await auth.createLocation({ name: 'Конкурентна', address: 'ул. X 1' });
  const a1 = await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE' });
  const a2 = await auth.createUser({ phone: phone(2), role: 'RESPONSIBLE' });
  const b1 = await auth.createUser({ phone: phone(3), role: 'RESPONSIBLE' });
  const b2 = await auth.createUser({ phone: phone(4), role: 'RESPONSIBLE' });

  const [firstResult, secondResult] = await Promise.all([
    setResponsibles(id, [a1, a2]),
    setResponsibles(id, [b1, b2]),
  ]);
  assert.equal(firstResult.status, 200);
  assert.equal(secondResult.status, 200);

  const read = await listResponsibles(id);
  const ids = read.body.responsibles.map((user) => user.id).sort((x, y) => x - y);
  const setA = [a1, a2].sort((x, y) => x - y);
  const setB = [b1, b2].sort((x, y) => x - y);
  const matchesA = JSON.stringify(ids) === JSON.stringify(setA);
  const matchesB = JSON.stringify(ids) === JSON.stringify(setB);
  assert.ok(matchesA || matchesB, `unexpected merged set: ${JSON.stringify(ids)}`);
});

test('assignment routes return 404 for a missing or archived location', async () => {
  const archivedId = await auth.createLocation({
    name: 'Архив',
    address: 'ул. X 1',
    isActive: false,
  });
  const userId = await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE' });

  for (const locationId of [99999999, archivedId]) {
    const read = await listResponsibles(locationId);
    assert.equal(read.status, 404, String(locationId));
    assert.equal(read.body.error.code, 'NOT_FOUND', String(locationId));

    const write = await setResponsibles(locationId, [userId]);
    assert.equal(write.status, 404, String(locationId));
    assert.equal(write.body.error.code, 'NOT_FOUND', String(locationId));
  }
});

test('assignment responses never leak internal security fields', async () => {
  const id = await auth.createLocation({ name: 'Сигурна', address: 'ул. X 1' });
  const userId = await auth.createUser({
    phone: phone(1),
    role: 'RESPONSIBLE',
    password: auth.TEST_PASSWORD,
  });
  await setResponsibles(id, [userId]);

  const res = await listResponsibles(id);
  const text = JSON.stringify(res.body);
  assert.ok(!text.includes('password'));
  assert.ok(!text.includes('hash'));
  assert.ok(!text.includes('token_version'));
  assert.ok(!text.includes('tokenVersion'));
  for (const user of res.body.responsibles) {
    assert.deepEqual(Object.keys(user).sort(), [...SAFE_KEYS].sort());
  }
});
