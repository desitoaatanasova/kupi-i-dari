'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const QUANTITY_KEYS = ['id', 'locationId', 'variantId', 'quantity'];
const BASE = 884100000;

let server;
let admin;
let adminToken;
let seq = 0;
let nameSeq = 0;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanQuantities();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanQuantities();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  admin = await auth.createAdminToken(server.baseUrl);
  adminToken = admin.token;
});

function nextPhone() {
  seq += 1;
  return `+359${BASE + seq}`;
}

function uniq(prefix) {
  nameSeq += 1;
  return `${prefix} ${nameSeq}`;
}

async function makeFixture() {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const productId = await auth.createProduct({ name: uniq('Продукт') });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 бр' });
  return { locationId, productId, variantId };
}

async function makeResponsible(locationIds = []) {
  const phone = nextPhone();
  const id = await auth.createUser({ phone, role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  for (const locationId of locationIds) {
    await auth.assignResponsible(id, locationId);
  }
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone,
    password: auth.TEST_PASSWORD,
  });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  return { id, token: res.body.token };
}

async function makeVolunteer() {
  const phone = nextPhone();
  const res = await auth.postJson(server.baseUrl, '/api/auth/volunteer', {
    firstName: 'Доброволец',
    lastName: 'Тестов',
    phone,
  });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  return { id: res.body.user.id, token: res.body.token };
}

test('quantity reads require authentication', async () => {
  const { locationId, variantId } = await makeFixture();
  const recordId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 3 });

  const list = await auth.getJson(server.baseUrl, '/api/quantities');
  assert.equal(list.status, 401);
  assert.equal(list.body.error.code, 'UNAUTHORIZED');

  const detail = await auth.getJson(server.baseUrl, `/api/quantities/${recordId}`);
  assert.equal(detail.status, 401);
  assert.equal(detail.body.error.code, 'UNAUTHORIZED');
});

test('volunteers are forbidden on quantity reads', async () => {
  const { locationId, variantId } = await makeFixture();
  const recordId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 3 });
  const { token } = await makeVolunteer();

  const list = await auth.getJson(server.baseUrl, '/api/quantities', token);
  assert.equal(list.status, 403);
  assert.equal(list.body.error.code, 'FORBIDDEN');

  const detail = await auth.getJson(server.baseUrl, `/api/quantities/${recordId}`, token);
  assert.equal(detail.status, 403);
  assert.equal(detail.body.error.code, 'FORBIDDEN');
});

test('admin reads records across locations with the exact safe shape', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const idA = await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 7,
  });
  const idB = await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 0,
  });

  const res = await auth.getJson(server.baseUrl, '/api/quantities', adminToken);
  assert.equal(res.status, 200);
  assert.equal(res.body.quantities.length, 2);

  const byId = new Map(res.body.quantities.map((q) => [q.id, q]));
  const ra = byId.get(idA);
  assert.deepEqual(Object.keys(ra).sort(), [...QUANTITY_KEYS].sort());
  assert.equal(ra.locationId, a.locationId);
  assert.equal(ra.variantId, a.variantId);
  assert.equal(ra.quantity, 7);
  assert.equal(byId.get(idB).quantity, 0);

  const detail = await auth.getJson(server.baseUrl, `/api/quantities/${idA}`, adminToken);
  assert.equal(detail.status, 200);
  assert.deepEqual(Object.keys(detail.body).sort(), [...QUANTITY_KEYS].sort());
  assert.equal(detail.body.id, idA);
  assert.equal(detail.body.locationId, a.locationId);
  assert.equal(detail.body.variantId, a.variantId);
  assert.equal(detail.body.quantity, 7);
});

test('lists records in ascending id order and handles the empty case', async () => {
  const empty = await auth.getJson(server.baseUrl, '/api/quantities', adminToken);
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.quantities, []);

  const a = await makeFixture();
  const b = await makeFixture();
  const first = await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 1,
  });
  const second = await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 2,
  });

  const res = await auth.getJson(server.baseUrl, '/api/quantities', adminToken);
  assert.deepEqual(
    res.body.quantities.map((q) => q.id),
    [first, second]
  );
});

test('responsible users only see quantities at assigned locations', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  const assignedId = await auth.createCollectedQuantity({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 4,
  });
  await auth.createCollectedQuantity({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 9,
  });

  const { token } = await makeResponsible([assigned.locationId]);

  const list = await auth.getJson(server.baseUrl, '/api/quantities', token);
  assert.equal(list.status, 200);
  assert.deepEqual(
    list.body.quantities.map((q) => q.id),
    [assignedId]
  );

  const own = await auth.getJson(server.baseUrl, `/api/quantities/${assignedId}`, token);
  assert.equal(own.status, 200);
  assert.equal(own.body.quantity, 4);
});

test('an explicit unassigned location filter returns 403 for responsible users', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  const { token } = await makeResponsible([assigned.locationId]);

  const bad = await auth.getJson(
    server.baseUrl,
    `/api/quantities?locationId=${other.locationId}`,
    token
  );
  assert.equal(bad.status, 403);
  assert.equal(bad.body.error.code, 'FORBIDDEN');

  const ok = await auth.getJson(
    server.baseUrl,
    `/api/quantities?locationId=${assigned.locationId}`,
    token
  );
  assert.equal(ok.status, 200);
});

test('responsible users cannot read another location record', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  const otherId = await auth.createCollectedQuantity({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 1,
  });
  const { token } = await makeResponsible([assigned.locationId]);

  const res = await auth.getJson(server.baseUrl, `/api/quantities/${otherId}`, token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('filters by location, variant and product', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const a1 = await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 1,
  });
  const b1 = await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 2,
  });

  const byLocation = await auth.getJson(
    server.baseUrl,
    `/api/quantities?locationId=${a.locationId}`,
    adminToken
  );
  assert.deepEqual(byLocation.body.quantities.map((q) => q.id), [a1]);

  const byVariant = await auth.getJson(
    server.baseUrl,
    `/api/quantities?variantId=${b.variantId}`,
    adminToken
  );
  assert.deepEqual(byVariant.body.quantities.map((q) => q.id), [b1]);

  const byProduct = await auth.getJson(
    server.baseUrl,
    `/api/quantities?productId=${a.productId}`,
    adminToken
  );
  assert.deepEqual(byProduct.body.quantities.map((q) => q.id), [a1]);
});

test('rejects malformed, empty, unknown and duplicate query parameters', async () => {
  const cases = [
    '/api/quantities?locationId=abc',
    '/api/quantities?locationId=0',
    '/api/quantities?locationId=1.5',
    '/api/quantities?locationId=',
    '/api/quantities?productId=-3',
    '/api/quantities?unknown=1',
    '/api/quantities?locationId=1&locationId=2',
  ];
  for (const path of cases) {
    const res = await auth.getJson(server.baseUrl, path, adminToken);
    assert.equal(res.status, 400, path);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', path);
  }
});

test('rejects malformed ids and returns 404 for missing records', async () => {
  for (const bad of ['abc', '0', '-1', '1.5']) {
    const res = await auth.getJson(server.baseUrl, `/api/quantities/${bad}`, adminToken);
    assert.equal(res.status, 400, bad);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', bad);
  }

  const missing = await auth.getJson(server.baseUrl, '/api/quantities/99999999', adminToken);
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');
});

test('never exposes actor, timestamp, shift or sensitive fields', async () => {
  const { locationId, variantId } = await makeFixture();
  const recordId = await auth.createCollectedQuantity({
    locationId,
    variantId,
    quantity: 5,
  });

  const res = await auth.getJson(server.baseUrl, `/api/quantities/${recordId}`, adminToken);
  assert.deepEqual(Object.keys(res.body).sort(), [...QUANTITY_KEYS].sort());

  for (const key of [
    'recordedBy',
    'recordedAt',
    'updatedAt',
    'shiftId',
    'shift_id',
    'recorded_by',
    'collected_quantity_id',
    'password_hash',
    'token',
  ]) {
    assert.ok(!(key in res.body), key);
  }
});
