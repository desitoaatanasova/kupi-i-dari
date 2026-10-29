'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const TOP_KEYS = ['totals', 'byLocation', 'byProduct'];
const TOTAL_KEYS = ['units', 'rows'];
const LOCATION_KEYS = ['locationId', 'locationName', 'units', 'rows'];
const PRODUCT_KEYS = ['productId', 'productName', 'category', 'units', 'rows'];

let server;
let adminToken;
let nameSeq = 0;

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
  const admin = await auth.createAdminToken(server.baseUrl);
  adminToken = admin.token;
});

function uniq(prefix) {
  nameSeq += 1;
  return `${prefix} ${nameSeq}`;
}

async function makeFixture(options = {}) {
  const locationName = uniq('Локация');
  const productName = uniq('Продукт');
  const locationId = await auth.createLocation({ name: locationName });
  const productId = await auth.createProduct({
    name: productName,
    category: options.category,
  });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 бр' });
  return { locationId, locationName, productId, productName, variantId };
}

function reportUrl(params = {}) {
  const qs = new URLSearchParams(params).toString();
  return qs ? `/api/reports/collected?${qs}` : '/api/reports/collected';
}

test('report requires authentication', async () => {
  const res = await auth.getJson(server.baseUrl, reportUrl());
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('volunteers are forbidden', async () => {
  const { token } = await auth.createVolunteerToken(server.baseUrl);
  const res = await auth.getJson(server.baseUrl, reportUrl(), token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('empty report returns zero totals, empty arrays and exact keys', async () => {
  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [...TOP_KEYS].sort());
  assert.deepEqual(Object.keys(res.body.totals).sort(), [...TOTAL_KEYS].sort());
  assert.deepEqual(res.body.totals, { units: 0, rows: 0 });
  assert.deepEqual(res.body.byLocation, []);
  assert.deepEqual(res.body.byProduct, []);
});

test('aggregates totals by location and product as numbers', async () => {
  const fx = await makeFixture({ category: 'Храни' });
  const v2 = await auth.createVariant({ productId: fx.productId, unitLabel: '2 бр' });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 3,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: v2,
    quantity: 4,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.status, 200, JSON.stringify(res.body));

  assert.deepEqual(res.body.totals, { units: 7, rows: 2 });
  assert.equal(typeof res.body.totals.units, 'number');
  assert.equal(typeof res.body.totals.rows, 'number');

  assert.equal(res.body.byLocation.length, 1);
  const loc = res.body.byLocation[0];
  assert.deepEqual(Object.keys(loc).sort(), [...LOCATION_KEYS].sort());
  assert.equal(loc.locationId, fx.locationId);
  assert.equal(loc.locationName, fx.locationName);
  assert.equal(loc.units, 7);
  assert.equal(loc.rows, 2);
  assert.equal(typeof loc.units, 'number');
  assert.equal(typeof loc.rows, 'number');

  assert.equal(res.body.byProduct.length, 1);
  const prod = res.body.byProduct[0];
  assert.deepEqual(Object.keys(prod).sort(), [...PRODUCT_KEYS].sort());
  assert.equal(prod.productId, fx.productId);
  assert.equal(prod.productName, fx.productName);
  assert.equal(prod.category, 'Храни');
  assert.equal(prod.units, 7);
  assert.equal(prod.rows, 2);
});

test('product category is null when unset', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 1,
  });
  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.body.byProduct[0].category, null);
});

test('groups are ordered by units descending, then id ascending', async () => {
  const low = await makeFixture();
  const high = await makeFixture();
  const tieA = await makeFixture();
  const tieB = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: low.locationId,
    variantId: low.variantId,
    quantity: 2,
  });
  await auth.createCollectedQuantity({
    locationId: high.locationId,
    variantId: high.variantId,
    quantity: 9,
  });
  await auth.createCollectedQuantity({
    locationId: tieA.locationId,
    variantId: tieA.variantId,
    quantity: 5,
  });
  await auth.createCollectedQuantity({
    locationId: tieB.locationId,
    variantId: tieB.variantId,
    quantity: 5,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(
    res.body.byLocation.map((g) => g.locationId),
    [high.locationId, tieA.locationId, tieB.locationId, low.locationId]
  );
  assert.deepEqual(res.body.byLocation.map((g) => g.units), [9, 5, 5, 2]);
});

test('zero-quantity rows are counted as recorded rows', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 0,
  });
  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(res.body.totals, { units: 0, rows: 1 });
  assert.equal(res.body.byLocation[0].units, 0);
  assert.equal(res.body.byLocation[0].rows, 1);
});

test('location and product groupings are independently correct', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 1,
  });
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: b.variantId,
    quantity: 2,
  });
  await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 4,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(res.body.totals, { units: 7, rows: 3 });

  const locById = new Map(res.body.byLocation.map((g) => [g.locationId, g]));
  assert.equal(locById.get(a.locationId).units, 3);
  assert.equal(locById.get(a.locationId).rows, 2);
  assert.equal(locById.get(b.locationId).units, 4);
  assert.equal(locById.get(b.locationId).rows, 1);

  const prodById = new Map(res.body.byProduct.map((g) => [g.productId, g]));
  assert.equal(prodById.get(a.productId).units, 1);
  assert.equal(prodById.get(b.productId).units, 6);
});

test('admin receives the unrestricted report', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 1,
  });
  await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 2,
  });
  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.body.totals.units, 3);
  assert.equal(res.body.byLocation.length, 2);
});

test('responsible users see only quantities at assigned locations', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 4,
  });
  await auth.createCollectedQuantity({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 9,
  });

  const { token } = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assigned.locationId],
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), token);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.totals, { units: 4, rows: 1 });
  assert.deepEqual(
    res.body.byLocation.map((g) => g.locationId),
    [assigned.locationId]
  );
  assert.deepEqual(
    res.body.byProduct.map((g) => g.productId),
    [assigned.productId]
  );
});

test('responsible user with no assigned locations receives zero totals', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 7,
  });
  const { token } = await auth.createResponsibleToken(server.baseUrl);

  const res = await auth.getJson(server.baseUrl, reportUrl(), token);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.totals, { units: 0, rows: 0 });
  assert.deepEqual(res.body.byLocation, []);
  assert.deepEqual(res.body.byProduct, []);
});

test('responsible explicit unassigned location filter returns 403', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  const { token } = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assigned.locationId],
  });

  const bad = await auth.getJson(
    server.baseUrl,
    reportUrl({ locationId: other.locationId }),
    token
  );
  assert.equal(bad.status, 403);
  assert.equal(bad.body.error.code, 'FORBIDDEN');

  const ok = await auth.getJson(
    server.baseUrl,
    reportUrl({ locationId: assigned.locationId }),
    token
  );
  assert.equal(ok.status, 200);
});

test('filters by locationId and productId', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 10,
  });
  await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 20,
  });

  const byLoc = await auth.getJson(
    server.baseUrl,
    reportUrl({ locationId: a.locationId }),
    adminToken
  );
  assert.deepEqual(byLoc.body.totals, { units: 10, rows: 1 });
  assert.deepEqual(
    byLoc.body.byLocation.map((g) => g.locationId),
    [a.locationId]
  );

  const byProd = await auth.getJson(
    server.baseUrl,
    reportUrl({ productId: b.productId }),
    adminToken
  );
  assert.deepEqual(byProd.body.totals, { units: 20, rows: 1 });
  assert.deepEqual(
    byProd.body.byProduct.map((g) => g.productId),
    [b.productId]
  );
});

test('filters by shiftId', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const shift1 = await auth.createShift({ status: 'OPEN', locationIds: [a.locationId] });
  const shift2 = await auth.createShift({ status: 'OPEN', locationIds: [a.locationId] });
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 3,
    shiftId: shift1,
  });
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: b.variantId,
    quantity: 5,
    shiftId: shift2,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl({ shiftId: shift1 }), adminToken);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.totals, { units: 3, rows: 1 });
});

test('date filters are inclusive on both boundaries', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const c = await makeFixture();
  const early = await auth.createShift({
    date: '2026-03-10',
    status: 'OPEN',
    locationIds: [a.locationId],
  });
  const mid = await auth.createShift({
    date: '2026-03-11',
    status: 'OPEN',
    locationIds: [b.locationId],
  });
  const late = await auth.createShift({
    date: '2026-03-12',
    status: 'OPEN',
    locationIds: [c.locationId],
  });
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 1,
    shiftId: early,
  });
  await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 2,
    shiftId: mid,
  });
  await auth.createCollectedQuantity({
    locationId: c.locationId,
    variantId: c.variantId,
    quantity: 4,
    shiftId: late,
  });

  const from = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-03-11' }),
    adminToken
  );
  assert.deepEqual(from.body.totals, { units: 6, rows: 2 });

  const to = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateTo: '2026-03-11' }),
    adminToken
  );
  assert.deepEqual(to.body.totals, { units: 3, rows: 2 });

  const exactFrom = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-03-12' }),
    adminToken
  );
  assert.deepEqual(exactFrom.body.totals, { units: 4, rows: 1 });

  const exactTo = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateTo: '2026-03-10' }),
    adminToken
  );
  assert.deepEqual(exactTo.body.totals, { units: 1, rows: 1 });

  const range = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-03-10', dateTo: '2026-03-11' }),
    adminToken
  );
  assert.deepEqual(range.body.totals, { units: 3, rows: 2 });
});

test('combines shift, location and product filters', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const shift1 = await auth.createShift({ status: 'OPEN', locationIds: [a.locationId] });
  const shift2 = await auth.createShift({ status: 'OPEN', locationIds: [a.locationId] });
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 6,
    shiftId: shift1,
  });
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: b.variantId,
    quantity: 6,
    shiftId: shift2,
  });

  const res = await auth.getJson(
    server.baseUrl,
    reportUrl({ shiftId: shift1, productId: a.productId, locationId: a.locationId }),
    adminToken
  );
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.totals, { units: 6, rows: 1 });
});

test('legacy unlinked rows appear in unfiltered reports', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 8,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(res.body.totals, { units: 8, rows: 1 });
  assert.equal(res.body.byLocation[0].locationId, fx.locationId);
  assert.deepEqual(
    res.body.byProduct.map((g) => g.productId),
    [fx.productId]
  );
});

test('legacy unlinked rows are excluded when a shift or date filter is applied', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 8,
  });
  const shift = await auth.createShift({
    date: '2026-03-10',
    status: 'OPEN',
    locationIds: [fx.locationId],
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 2,
    shiftId: shift,
  });

  const byShift = await auth.getJson(
    server.baseUrl,
    reportUrl({ shiftId: shift }),
    adminToken
  );
  assert.deepEqual(byShift.body.totals, { units: 2, rows: 1 });

  const byDateFrom = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-03-01' }),
    adminToken
  );
  assert.deepEqual(byDateFrom.body.totals, { units: 2, rows: 1 });

  const byDateTo = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateTo: '2026-03-31' }),
    adminToken
  );
  assert.deepEqual(byDateTo.body.totals, { units: 2, rows: 1 });

  const unfiltered = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(unfiltered.body.totals, { units: 10, rows: 2 });
});

test('rejects unknown, malformed and duplicate query parameters', async () => {
  const cases = [
    '/api/reports/collected?unknown=1',
    '/api/reports/collected?shiftId=abc',
    '/api/reports/collected?shiftId=0',
    '/api/reports/collected?locationId=1.5',
    '/api/reports/collected?productId=-1',
    '/api/reports/collected?dateFrom=2026-02-30',
    '/api/reports/collected?dateTo=not-a-date',
    '/api/reports/collected?dateFrom=2026-03-10&dateFrom=2026-03-11',
    '/api/reports/collected?dateFrom=2026-03-10&dateTo=2026-03-09',
  ];
  for (const path of cases) {
    const res = await auth.getJson(server.baseUrl, path, adminToken);
    assert.equal(res.status, 400, path);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', path);
  }
});

test('never leaks audit or personal fields', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 2,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  const text = JSON.stringify(res.body);
  for (const key of [
    'recorded_by',
    'recordedBy',
    'recorded_at',
    'recordedAt',
    'updated_at',
    'updatedAt',
    'phone',
    'firstName',
    'lastName',
    'token',
    'password_hash',
    'collected_quantity_id',
    'variant_id',
    'shift_id',
  ]) {
    assert.ok(!text.includes(key), key);
  }

  assert.deepEqual(Object.keys(res.body).sort(), [...TOP_KEYS].sort());
  assert.deepEqual(Object.keys(res.body.totals).sort(), [...TOTAL_KEYS].sort());
  for (const group of res.body.byLocation) {
    assert.deepEqual(Object.keys(group).sort(), [...LOCATION_KEYS].sort());
  }
  for (const group of res.body.byProduct) {
    assert.deepEqual(Object.keys(group).sort(), [...PRODUCT_KEYS].sort());
  }
});
