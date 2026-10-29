'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const DISTRIBUTION_KEYS = ['id', 'locationId', 'variantId', 'quantity', 'date', 'recipient', 'note'];

let server;
let adminToken;
let nameSeq = 0;
let phoneSeq = 0;

const nextPhone = () => {
  phoneSeq += 1;
  return `+359${884400000 + phoneSeq}`;
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
  const admin = await auth.createAdminToken(server.baseUrl);
  adminToken = admin.token;
});

function uniq(prefix) {
  nameSeq += 1;
  return `${prefix} ${nameSeq}`;
}

// A location + product + variant fixture. Returns the created ids.
async function makeFixture() {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const productId = await auth.createProduct({ name: uniq('Продукт') });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 бр' });
  return { locationId, productId, variantId };
}

async function makeResponsible(locationIds = []) {
  const phone = nextPhone();
  const id = await auth.createUser({
    phone,
    role: 'RESPONSIBLE',
    password: auth.TEST_PASSWORD,
  });
  for (const locationId of locationIds) {
    await auth.assignResponsible(id, locationId);
  }
  const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
    phone,
    password: auth.TEST_PASSWORD,
  });
  return { id, token: res.body.token };
}

const listUrl = (query = '') => `/api/distributions${query}`;

test('listing and reading require authentication', async () => {
  const { locationId, variantId } = await makeFixture();
  const id = await auth.createDistribution({ locationId, variantId, quantity: 2 });

  const list = await auth.getJson(server.baseUrl, listUrl());
  assert.equal(list.status, 401);

  const read = await auth.getJson(server.baseUrl, `/api/distributions/${id}`);
  assert.equal(read.status, 401);
});

test('volunteers are forbidden from reading distributions', async () => {
  const { locationId, variantId } = await makeFixture();
  const id = await auth.createDistribution({ locationId, variantId, quantity: 2 });
  const { token } = await auth.createVolunteerToken(server.baseUrl);

  const list = await auth.getJson(server.baseUrl, listUrl(), token);
  assert.equal(list.status, 403);
  assert.equal(list.body.error.code, 'FORBIDDEN');

  const read = await auth.getJson(server.baseUrl, `/api/distributions/${id}`, token);
  assert.equal(read.status, 403);
});

test('admin lists distributions with the exact safe shape and deterministic order', async () => {
  const { locationId, variantId } = await makeFixture();
  const first = await auth.createDistribution({
    locationId,
    variantId,
    quantity: 5,
    recipient: 'Дом',
  });
  const second = await auth.createDistribution({ locationId, variantId, quantity: 3 });
  const third = await auth.createDistribution({ locationId, variantId, quantity: 1 });

  const res = await auth.getJson(server.baseUrl, listUrl(), adminToken);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body), ['distributions']);
  assert.deepEqual(
    res.body.distributions.map((d) => d.id),
    [first, second, third]
  );

  for (const item of res.body.distributions) {
    assert.deepEqual(Object.keys(item).sort(), [...DISTRIBUTION_KEYS].sort());
  }

  const [doc] = res.body.distributions;
  assert.equal(doc.locationId, locationId);
  assert.equal(doc.variantId, variantId);
  assert.equal(doc.quantity, 5);
  assert.equal(doc.recipient, 'Дом');
  assert.equal(doc.note, null);
  assert.match(doc.date, /^\d{4}-\d{2}-\d{2}$/);

  const text = JSON.stringify(res.body);
  for (const key of ['distributed_by', 'distributedBy', 'distributed_at', 'distributedAt']) {
    assert.ok(!text.includes(key), key);
  }
});

test('reading one distribution returns the exact safe shape', async () => {
  const { locationId, variantId } = await makeFixture();
  const id = await auth.createDistribution({
    locationId,
    variantId,
    quantity: 7,
    recipient: 'Училище',
    note: 'партида 2',
  });

  const res = await auth.getJson(server.baseUrl, `/api/distributions/${id}`, adminToken);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [...DISTRIBUTION_KEYS].sort());
  assert.deepEqual(res.body, {
    id,
    locationId,
    variantId,
    quantity: 7,
    date: '2026-11-01',
    recipient: 'Училище',
    note: 'партида 2',
  });
});

test('filters by locationId, variantId, productId and date range', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const otherVariant = await auth.createVariant({ productId: a.productId, unitLabel: '500 г' });

  const target = await auth.createDistribution({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 4,
    distributionDate: '2026-11-05',
  });
  await auth.createDistribution({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 9,
    distributionDate: '2026-11-10',
  });
  const sameProduct = await auth.createDistribution({
    locationId: a.locationId,
    variantId: otherVariant,
    quantity: 2,
    distributionDate: '2026-11-06',
  });

  const byLocation = await auth.getJson(
    server.baseUrl,
    listUrl(`?locationId=${a.locationId}`),
    adminToken
  );
  assert.deepEqual(
    byLocation.body.distributions.map((d) => d.id).sort((x, y) => x - y),
    [target, sameProduct]
  );

  const byVariant = await auth.getJson(
    server.baseUrl,
    listUrl(`?variantId=${otherVariant}`),
    adminToken
  );
  assert.deepEqual(byVariant.body.distributions.map((d) => d.id), [sameProduct]);

  const byProduct = await auth.getJson(
    server.baseUrl,
    listUrl(`?productId=${a.productId}`),
    adminToken
  );
  assert.deepEqual(
    byProduct.body.distributions.map((d) => d.id).sort((x, y) => x - y),
    [target, sameProduct]
  );

  // Inclusive boundaries.
  const byDate = await auth.getJson(
    server.baseUrl,
    listUrl('?dateFrom=2026-11-05&dateTo=2026-11-06'),
    adminToken
  );
  assert.deepEqual(
    byDate.body.distributions.map((d) => d.id).sort((x, y) => x - y),
    [target, sameProduct]
  );

  const combined = await auth.getJson(
    server.baseUrl,
    listUrl(`?locationId=${a.locationId}&productId=${a.productId}&dateFrom=2026-11-06`),
    adminToken
  );
  assert.deepEqual(combined.body.distributions.map((d) => d.id), [sameProduct]);
});

test('rejects unknown, duplicate, malformed and reversed query parameters', async () => {
  const { locationId } = await makeFixture();

  const unknown = await auth.getJson(server.baseUrl, listUrl('?bogus=1'), adminToken);
  assert.equal(unknown.status, 400);
  assert.equal(unknown.body.error.code, 'VALIDATION_ERROR');

  const duplicate = await auth.getJson(
    server.baseUrl,
    listUrl(`?locationId=${locationId}&locationId=${locationId}`),
    adminToken
  );
  assert.equal(duplicate.status, 400);

  const malformedDate = await auth.getJson(
    server.baseUrl,
    listUrl('?dateFrom=2026-13-01'),
    adminToken
  );
  assert.equal(malformedDate.status, 400);

  const reversed = await auth.getJson(
    server.baseUrl,
    listUrl('?dateFrom=2026-11-10&dateTo=2026-11-01'),
    adminToken
  );
  assert.equal(reversed.status, 400);
  assert.equal(reversed.body.error.code, 'VALIDATION_ERROR');
});

test('malformed ids return 400 and missing records return 404', async () => {
  const malformed = await auth.getJson(server.baseUrl, '/api/distributions/abc', adminToken);
  assert.equal(malformed.status, 400);

  const missing = await auth.getJson(server.baseUrl, '/api/distributions/999999', adminToken);
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');
});

test('responsible users only see and read their assigned locations', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const mine = await auth.createDistribution({ locationId: a.locationId, variantId: a.variantId });
  await auth.createDistribution({ locationId: b.locationId, variantId: b.variantId });

  const responsible = await makeResponsible([a.locationId]);

  const list = await auth.getJson(server.baseUrl, listUrl(), responsible.token);
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.distributions.map((d) => d.id), [mine]);

  const explicitUnassigned = await auth.getJson(
    server.baseUrl,
    listUrl(`?locationId=${b.locationId}`),
    responsible.token
  );
  assert.equal(explicitUnassigned.status, 403);

  const [otherRow] = (
    await auth.pool.query('SELECT distribution_id FROM distributions WHERE location_id = ?', [
      b.locationId,
    ])
  )[0];
  const readOther = await auth.getJson(
    server.baseUrl,
    `/api/distributions/${otherRow.distribution_id}`,
    responsible.token
  );
  assert.equal(readOther.status, 403);

  const readMine = await auth.getJson(
    server.baseUrl,
    `/api/distributions/${mine}`,
    responsible.token
  );
  assert.equal(readMine.status, 200);
});
