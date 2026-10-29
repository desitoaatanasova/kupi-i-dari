'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const DISTRIBUTION_KEYS = ['id', 'locationId', 'variantId', 'quantity', 'date', 'recipient', 'note'];

let server;
let admin;
let adminToken;
let nameSeq = 0;
let phoneSeq = 0;

const nextPhone = () => {
  phoneSeq += 1;
  return `+359${884500000 + phoneSeq}`;
};

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanDistributions();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanDistributions();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  admin = await auth.createAdminToken(server.baseUrl);
  adminToken = admin.token;
});

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
  return { id, token: res.body.token };
}

const post = (body, token = adminToken) =>
  auth.postJson(server.baseUrl, '/api/distributions', body, token);
const patch = (id, body, token = adminToken) =>
  auth.patchJson(server.baseUrl, `/api/distributions/${id}`, body, token);

test('distribution writes require authentication', async () => {
  const { locationId, variantId } = await makeFixture();
  const id = await auth.createDistribution({ locationId, variantId, quantity: 1 });

  const created = await post({ locationId, variantId, quantity: 1 }, null);
  assert.equal(created.status, 401);

  const updated = await patch(id, { quantity: 2 }, null);
  assert.equal(updated.status, 401);
});

test('volunteers are forbidden from writing distributions', async () => {
  const { locationId, variantId } = await makeFixture();
  const id = await auth.createDistribution({ locationId, variantId, quantity: 1 });
  const { token } = await auth.createVolunteerToken(server.baseUrl);

  const created = await post({ locationId, variantId, quantity: 5 }, token);
  assert.equal(created.status, 403);
  assert.equal(created.body.error.code, 'FORBIDDEN');

  const updated = await patch(id, { quantity: 5 }, token);
  assert.equal(updated.status, 403);
});

test('creates a distribution with the exact safe shape', async () => {
  const { locationId, variantId } = await makeFixture();

  const res = await post({
    locationId,
    variantId,
    quantity: 12,
    recipient: 'Дом за възрастни',
    note: 'партида 1',
  });

  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(res.body).sort(), [...DISTRIBUTION_KEYS].sort());
  assert.equal(res.body.locationId, locationId);
  assert.equal(res.body.variantId, variantId);
  assert.equal(res.body.quantity, 12);
  assert.equal(res.body.recipient, 'Дом за възрастни');
  assert.equal(res.body.note, 'партида 1');
  assert.match(res.body.date, /^\d{4}-\d{2}-\d{2}$/);

  const text = JSON.stringify(res.body);
  for (const key of [
    'distributed_by',
    'distributedBy',
    'distributed_at',
    'distributedAt',
    'password',
    'token_version',
  ]) {
    assert.ok(!text.includes(key), key);
  }
});

test('recipient and note are optional and default to null', async () => {
  const { locationId, variantId } = await makeFixture();
  const res = await post({ locationId, variantId, quantity: 3 });
  assert.equal(res.status, 201);
  assert.equal(res.body.recipient, null);
  assert.equal(res.body.note, null);
});

test('multiple identical POSTs create distinct event records', async () => {
  const { locationId, variantId } = await makeFixture();

  const a = await post({ locationId, variantId, quantity: 5 });
  const b = await post({ locationId, variantId, quantity: 5 });
  const c = await post({ locationId, variantId, quantity: 5 });

  assert.equal(a.status, 201);
  assert.equal(b.status, 201);
  assert.equal(c.status, 201);
  const ids = new Set([a.body.id, b.body.id, c.body.id]);
  assert.equal(ids.size, 3);

  const [rows] = await auth.pool.query(
    'SELECT COUNT(*) AS n FROM distributions WHERE location_id = ? AND variant_id = ?',
    [locationId, variantId]
  );
  assert.equal(Number(rows[0].n), 3);
});

test('records the authenticated distributor, never a client-supplied one', async () => {
  const { locationId, variantId } = await makeFixture();

  const res = await post({ locationId, variantId, quantity: 1, distributedBy: 999999 });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');

  const ok = await post({ locationId, variantId, quantity: 1 });
  assert.equal(ok.status, 201);

  const [rows] = await auth.pool.query(
    'SELECT distributed_by FROM distributions WHERE distribution_id = ?',
    [ok.body.id]
  );
  assert.equal(rows[0].distributed_by, admin.id);
});

test('rejects missing, malformed and out-of-range fields', async () => {
  const { locationId, variantId } = await makeFixture();

  const cases = [
    {},
    { locationId, variantId },
    { locationId, variantId, quantity: 0 },
    { locationId, variantId, quantity: -3 },
    { locationId, variantId, quantity: 1.5 },
    { locationId, variantId, quantity: 2147483648 },
    { locationId, variantId, quantity: '5' },
    { locationId: 'x', variantId, quantity: 1 },
    { locationId, variantId, quantity: 1, recipient: 5 },
    { locationId, variantId, quantity: 1, recipient: '' },
    { locationId, variantId, quantity: 1, recipient: 'x'.repeat(161) },
    { locationId, variantId, quantity: 1, note: 'x'.repeat(256) },
  ];

  for (const body of cases) {
    const res = await post(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});

test('rejects unknown body fields', async () => {
  const { locationId, variantId } = await makeFixture();
  const res = await post({ locationId, variantId, quantity: 1, date: '2026-01-01' });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('rejects missing or inactive locations', async () => {
  const { variantId } = await makeFixture();

  const missing = await post({ locationId: 999999, variantId, quantity: 1 });
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');

  const inactiveLocation = await auth.createLocation({
    name: uniq('Архив'),
    isActive: false,
  });
  const inactive = await post({ locationId: inactiveLocation, variantId, quantity: 1 });
  assert.equal(inactive.status, 404);
});

test('rejects missing variants and inactive parent products', async () => {
  const { locationId } = await makeFixture();

  const missingVariant = await post({ locationId, variantId: 999999, quantity: 1 });
  assert.equal(missingVariant.status, 404);

  const inactiveProduct = await auth.createProduct({
    name: uniq('Неактивен'),
    isActive: false,
  });
  const variantOfInactive = await auth.createVariant({
    productId: inactiveProduct,
    unitLabel: '1 кг',
  });
  const res = await post({ locationId, variantId: variantOfInactive, quantity: 1 });
  assert.equal(res.status, 404);
});

test('corrects quantity, recipient and note absolutely and clears with null', async () => {
  const { locationId, variantId } = await makeFixture();
  const created = await post({
    locationId,
    variantId,
    quantity: 4,
    recipient: 'Стар',
    note: 'стара бележка',
  });

  const updated = await patch(created.body.id, {
    quantity: 9,
    recipient: 'Нов',
    note: 'нова бележка',
  });
  assert.equal(updated.status, 200);
  assert.equal(updated.body.quantity, 9);
  assert.equal(updated.body.recipient, 'Нов');
  assert.equal(updated.body.note, 'нова бележка');

  const cleared = await patch(created.body.id, { recipient: null, note: null });
  assert.equal(cleared.status, 200);
  assert.equal(cleared.body.recipient, null);
  assert.equal(cleared.body.note, null);
  assert.equal(cleared.body.quantity, 9);
});

test('rejects empty and unknown-field updates and immutable fields', async () => {
  const { locationId, variantId } = await makeFixture();
  const created = await post({ locationId, variantId, quantity: 1 });

  const empty = await patch(created.body.id, {});
  assert.equal(empty.status, 400);

  const unknown = await patch(created.body.id, { bogus: 1 });
  assert.equal(unknown.status, 400);

  const immutableLocation = await patch(created.body.id, { locationId: 999 });
  assert.equal(immutableLocation.status, 400);

  const immutableVariant = await patch(created.body.id, { variantId: 999 });
  assert.equal(immutableVariant.status, 400);

  const invalidQuantity = await patch(created.body.id, { quantity: 0 });
  assert.equal(invalidQuantity.status, 400);
  assert.equal(invalidQuantity.body.error.code, 'VALIDATION_ERROR');
});

test('updating a missing record returns 404 and a malformed id returns 400', async () => {
  const malformed = await patch('abc', { quantity: 1 });
  assert.equal(malformed.status, 400);

  const missing = await patch(999999, { quantity: 1 });
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');
});

test('a responsible user may write only at assigned locations', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const responsible = await makeResponsible([a.locationId]);

  const mine = await post(
    { locationId: a.locationId, variantId: a.variantId, quantity: 1 },
    responsible.token
  );
  assert.equal(mine.status, 201);

  const forbidden = await post(
    { locationId: b.locationId, variantId: b.variantId, quantity: 1 },
    responsible.token
  );
  assert.equal(forbidden.status, 403);
  assert.equal(forbidden.body.error.code, 'FORBIDDEN');

  const other = await auth.createDistribution({ locationId: b.locationId, variantId: b.variantId });
  const updateOther = await patch(other, { quantity: 2 }, responsible.token);
  assert.equal(updateOther.status, 403);

  const updateMine = await patch(mine.body.id, { quantity: 2 }, responsible.token);
  assert.equal(updateMine.status, 200);
  assert.equal(updateMine.body.quantity, 2);
});

test('corrections survive later archival of location, variant and product', async () => {
  const { locationId, productId, variantId } = await makeFixture();
  const created = await post({ locationId, variantId, quantity: 3 });
  assert.equal(created.status, 201);

  await auth.pool.query('UPDATE locations SET is_active = 0 WHERE location_id = ?', [locationId]);
  const afterLocation = await patch(created.body.id, { quantity: 4 });
  assert.equal(afterLocation.status, 200);

  await auth.pool.query('UPDATE product_variants SET is_active = 0 WHERE variant_id = ?', [
    variantId,
  ]);
  const afterVariant = await patch(created.body.id, { quantity: 5 });
  assert.equal(afterVariant.status, 200);

  await auth.pool.query('UPDATE products SET is_active = 0 WHERE product_id = ?', [productId]);
  const afterProduct = await patch(created.body.id, { quantity: 6 });
  assert.equal(afterProduct.status, 200);
  assert.equal(afterProduct.body.quantity, 6);
});

test('concurrent POSTs persist as distinct rows without deadlocks', async () => {
  const { locationId, variantId } = await makeFixture();

  const results = await Promise.all(
    [11, 22, 33, 44, 55].map((quantity) => post({ locationId, variantId, quantity }))
  );
  assert.ok(
    results.every((r) => r.status === 201),
    JSON.stringify(results.map((r) => r.status))
  );
  const ids = new Set(results.map((r) => r.body.id));
  assert.equal(ids.size, 5);

  const [rows] = await auth.pool.query(
    'SELECT COUNT(*) AS n FROM distributions WHERE location_id = ? AND variant_id = ?',
    [locationId, variantId]
  );
  assert.equal(Number(rows[0].n), 5);
});

test('forced-password-change enforcement still applies to distributions', async () => {
  const { locationId, variantId } = await makeFixture();
  const id = await auth.createDistribution({ locationId, variantId, quantity: 1 });

  await auth.pool.query('UPDATE users SET must_change_password = 1 WHERE user_id = ?', [admin.id]);

  const list = await auth.getJson(server.baseUrl, '/api/distributions', adminToken);
  assert.equal(list.status, 403);
  assert.equal(list.body.error.code, 'MUST_CHANGE_PASSWORD');

  const created = await post({ locationId, variantId, quantity: 1 });
  assert.equal(created.status, 403);
  assert.equal(created.body.error.code, 'MUST_CHANGE_PASSWORD');

  const updated = await patch(id, { quantity: 2 });
  assert.equal(updated.status, 403);
  assert.equal(updated.body.error.code, 'MUST_CHANGE_PASSWORD');
});
