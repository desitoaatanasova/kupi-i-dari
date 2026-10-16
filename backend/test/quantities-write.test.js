'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const QUANTITY_KEYS = ['id', 'locationId', 'variantId', 'quantity'];
const BASE = 884200000;

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

const post = (body, token = adminToken) =>
  auth.postJson(server.baseUrl, '/api/quantities', body, token);

test('quantity writes require authentication', async () => {
  const { locationId, variantId } = await makeFixture();

  const created = await auth.postJson(server.baseUrl, '/api/quantities', {
    locationId,
    variantId,
    quantity: 1,
  });
  assert.equal(created.status, 401);

  const recordId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 1 });
  const updated = await auth.patchJson(server.baseUrl, `/api/quantities/${recordId}`, {
    quantity: 2,
  });
  assert.equal(updated.status, 401);
});

test('volunteers are forbidden from writing quantities', async () => {
  const { locationId, variantId } = await makeFixture();
  const recordId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 1 });
  const { token } = await makeVolunteer();

  const created = await post({ locationId, variantId, quantity: 5 }, token);
  assert.equal(created.status, 403);
  assert.equal(created.body.error.code, 'FORBIDDEN');

  const updated = await auth.patchJson(
    server.baseUrl,
    `/api/quantities/${recordId}`,
    { quantity: 5 },
    token
  );
  assert.equal(updated.status, 403);
  assert.equal(updated.body.error.code, 'FORBIDDEN');
});

test('admin creates a quantity (201) with the safe shape and records the actor', async () => {
  const { locationId, variantId } = await makeFixture();

  const res = await post({ locationId, variantId, quantity: 12 });
  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(res.body).sort(), [...QUANTITY_KEYS].sort());
  assert.equal(res.body.locationId, locationId);
  assert.equal(res.body.variantId, variantId);
  assert.equal(res.body.quantity, 12);

  const [rows] = await auth.pool.query(
    'SELECT quantity, recorded_by, shift_id FROM collected_quantities WHERE location_id = ? AND variant_id = ?',
    [locationId, variantId]
  );
  assert.equal(rows.length, 1);
  assert.equal(Number(rows[0].quantity), 12);
  assert.equal(Number(rows[0].recorded_by), admin.id);
  assert.equal(rows[0].shift_id, null);
});

test('repeating a POST replaces the quantity (200) and keeps a single row', async () => {
  const { locationId, variantId } = await makeFixture();

  const first = await post({ locationId, variantId, quantity: 5 });
  assert.equal(first.status, 201);

  const second = await post({ locationId, variantId, quantity: 3 });
  assert.equal(second.status, 200);
  assert.equal(second.body.id, first.body.id);
  assert.equal(second.body.quantity, 3);

  const [rows] = await auth.pool.query(
    'SELECT collected_quantity_id, quantity FROM collected_quantities WHERE location_id = ? AND variant_id = ?',
    [locationId, variantId]
  );
  assert.equal(rows.length, 1);
  assert.equal(Number(rows[0].quantity), 3);
});

test('records the acting user on both create and replace', async () => {
  const { locationId, variantId } = await makeFixture();
  const resp = await makeResponsible([locationId]);

  const created = await post({ locationId, variantId, quantity: 1 }, resp.token);
  assert.equal(created.status, 201);
  const [afterCreate] = await auth.pool.query(
    'SELECT recorded_by FROM collected_quantities WHERE location_id = ? AND variant_id = ?',
    [locationId, variantId]
  );
  assert.equal(Number(afterCreate[0].recorded_by), resp.id);

  const replaced = await post({ locationId, variantId, quantity: 2 });
  assert.equal(replaced.status, 200);
  const [afterReplace] = await auth.pool.query(
    'SELECT recorded_by FROM collected_quantities WHERE location_id = ? AND variant_id = ?',
    [locationId, variantId]
  );
  assert.equal(Number(afterReplace[0].recorded_by), admin.id);
});

test('rejects invalid create payloads', async () => {
  const { locationId, variantId } = await makeFixture();
  const cases = [
    {},
    { locationId, variantId },
    { locationId, variantId, quantity: -1 },
    { locationId, variantId, quantity: 1.5 },
    { locationId, variantId, quantity: '3' },
    { locationId: 'x', variantId, quantity: 1 },
    { locationId: 0, variantId, quantity: 1 },
    { locationId, variantId, quantity: 1, extra: true },
    { locationId, variantId, quantity: 2147483648 },
    [1, 2, 3],
  ];

  for (const body of cases) {
    const res = await post(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('rejects malformed JSON bodies', async () => {
  const response = await fetch(`${server.baseUrl}/api/quantities`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${adminToken}` },
    body: '{not valid json',
  });
  assert.equal(response.status, 400);
});

test('accepts a zero quantity', async () => {
  const { locationId, variantId } = await makeFixture();
  const res = await post({ locationId, variantId, quantity: 0 });
  assert.equal(res.status, 201);
  assert.equal(res.body.quantity, 0);
});

test('POST returns 404 for missing or inactive references', async () => {
  const { locationId, variantId } = await makeFixture();
  const archivedLocation = await auth.createLocation({
    name: uniq('Локация архивирана'),
    isActive: false,
  });
  const archivedVariantProduct = await auth.createProduct({ name: uniq('Продукт') });
  const archivedVariant = await auth.createVariant({
    productId: archivedVariantProduct,
    unitLabel: '1 бр',
    isActive: false,
  });
  const archivedProduct = await auth.createProduct({
    name: uniq('Продукт архивиран'),
    isActive: false,
  });
  const variantUnderArchived = await auth.createVariant({
    productId: archivedProduct,
    unitLabel: '1 бр',
  });

  const cases = [
    { locationId: 99999999, variantId, quantity: 1 },
    { locationId, variantId: 99999999, quantity: 1 },
    { locationId: archivedLocation, variantId, quantity: 1 },
    { locationId, variantId: archivedVariant, quantity: 1 },
    { locationId, variantId: variantUnderArchived, quantity: 1 },
  ];

  for (const body of cases) {
    const res = await post(body);
    assert.equal(res.status, 404, JSON.stringify(body));
    assert.equal(res.body.error.code, 'NOT_FOUND', JSON.stringify(body));
  }
});

test('a rejected creation leaves no quantity row', async () => {
  const { locationId } = await makeFixture();
  const productId = await auth.createProduct({ name: uniq('Продукт') });
  const archivedVariant = await auth.createVariant({
    productId,
    unitLabel: '1 бр',
    isActive: false,
  });

  const res = await post({ locationId, variantId: archivedVariant, quantity: 1 });
  assert.equal(res.status, 404);

  const [rows] = await auth.pool.query('SELECT COUNT(*) AS total FROM collected_quantities');
  assert.equal(Number(rows[0].total), 0);
});

test('responsible users can write only at assigned locations', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  const resp = await makeResponsible([assigned.locationId]);

  const ok = await post(
    { locationId: assigned.locationId, variantId: assigned.variantId, quantity: 2 },
    resp.token
  );
  assert.equal(ok.status, 201);

  const denied = await post(
    { locationId: other.locationId, variantId: other.variantId, quantity: 2 },
    resp.token
  );
  assert.equal(denied.status, 403);
  assert.equal(denied.body.error.code, 'FORBIDDEN');

  const replaced = await post(
    { locationId: assigned.locationId, variantId: assigned.variantId, quantity: 4 },
    resp.token
  );
  assert.equal(replaced.status, 200);
  assert.equal(replaced.body.quantity, 4);
});

test('PATCH replaces the absolute quantity with the safe shape', async () => {
  const { locationId, variantId } = await makeFixture();
  const recordId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 9 });

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/quantities/${recordId}`,
    { quantity: 4 },
    adminToken
  );
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [...QUANTITY_KEYS].sort());
  assert.equal(res.body.id, recordId);
  assert.equal(res.body.locationId, locationId);
  assert.equal(res.body.variantId, variantId);
  assert.equal(res.body.quantity, 4);

  const [rows] = await auth.pool.query(
    'SELECT quantity FROM collected_quantities WHERE collected_quantity_id = ?',
    [recordId]
  );
  assert.equal(Number(rows[0].quantity), 4);
});

test('PATCH validates the id and body', async () => {
  const { locationId, variantId } = await makeFixture();
  const recordId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 1 });

  for (const bad of ['abc', '0', '-1', '1.5']) {
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/quantities/${bad}`,
      { quantity: 1 },
      adminToken
    );
    assert.equal(res.status, 400, bad);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', bad);
  }

  const bodyCases = [
    {},
    { quantity: -1 },
    { quantity: 1.5 },
    { quantity: '2' },
    { quantity: 1, extra: true },
    { quantity: 2147483648 },
  ];
  for (const body of bodyCases) {
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/quantities/${recordId}`,
      body,
      adminToken
    );
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }

  const missing = await auth.patchJson(
    server.baseUrl,
    '/api/quantities/99999999',
    { quantity: 1 },
    adminToken
  );
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');
});

test('PATCH can correct a record after its linked location and variant are archived', async () => {
  const { locationId, variantId } = await makeFixture();
  const recordId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 2 });

  await auth.pool.query('UPDATE product_variants SET is_active = 0 WHERE variant_id = ?', [variantId]);
  await auth.pool.query('UPDATE locations SET is_active = 0 WHERE location_id = ?', [locationId]);

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/quantities/${recordId}`,
    { quantity: 6 },
    adminToken
  );
  assert.equal(res.status, 200);
  assert.equal(res.body.quantity, 6);
});

test('an unassigned responsible cannot update a record', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  const otherId = await auth.createCollectedQuantity({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 1,
  });
  const resp = await makeResponsible([assigned.locationId]);

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/quantities/${otherId}`,
    { quantity: 5 },
    resp.token
  );
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('concurrent POSTs never duplicate a pair and settle on one value', async () => {
  const { locationId, variantId } = await makeFixture();
  const values = [11, 22, 33, 44, 55];

  const results = await Promise.all(
    values.map((quantity) => post({ locationId, variantId, quantity }))
  );

  const statuses = results.map((r) => r.status);
  assert.ok(
    statuses.every((s) => s === 200 || s === 201),
    JSON.stringify(statuses)
  );
  assert.equal(statuses.filter((s) => s === 201).length, 1);

  const [rows] = await auth.pool.query(
    'SELECT quantity FROM collected_quantities WHERE location_id = ? AND variant_id = ?',
    [locationId, variantId]
  );
  assert.equal(rows.length, 1);
  assert.ok(
    values.includes(Number(rows[0].quantity)),
    `final value ${rows[0].quantity} must be one of ${JSON.stringify(values)}`
  );
});
