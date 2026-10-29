'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const TOP_KEYS = ['totals', 'byLocation', 'byProduct', 'byVariant'];
const TOTAL_KEYS = ['collectedQuantity', 'distributedQuantity', 'remainingQuantity'];
const LOCATION_KEYS = [
  'locationId',
  'locationName',
  'collectedQuantity',
  'distributedQuantity',
  'remainingQuantity',
];
const PRODUCT_KEYS = [
  'productId',
  'productName',
  'category',
  'collectedQuantity',
  'distributedQuantity',
  'remainingQuantity',
];
const VARIANT_KEYS = [
  'variantId',
  'productId',
  'productName',
  'unitLabel',
  'collectedQuantity',
  'distributedQuantity',
  'remainingQuantity',
];

let server;
let adminToken;
let nameSeq = 0;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanDistributions();
  await auth.cleanQuantities();
  await auth.cleanShifts();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanDistributions();
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
  return qs ? `/api/reports/inventory?${qs}` : '/api/reports/inventory';
}

// ---------------------------------------------------------------------------
// Authentication and authorization
// ---------------------------------------------------------------------------

test('inventory report requires authentication', async () => {
  const res = await auth.getJson(server.baseUrl, reportUrl());
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('volunteers are forbidden from the inventory report', async () => {
  const { token } = await auth.createVolunteerToken(server.baseUrl);
  const res = await auth.getJson(server.baseUrl, reportUrl(), token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('admin can report across locations', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 3,
  });
  await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 9,
  });
  await auth.createDistribution({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 4,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 12,
    distributedQuantity: 4,
    remainingQuantity: 8,
  });
  assert.equal(res.body.byLocation.length, 2);
});

test('responsible users see only assigned locations in every section', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 4,
  });
  await auth.createDistribution({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 1,
  });
  await auth.createCollectedQuantity({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 9,
  });
  await auth.createDistribution({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 5,
  });

  const { token } = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assigned.locationId],
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), token);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 4,
    distributedQuantity: 1,
    remainingQuantity: 3,
  });
  assert.deepEqual(
    res.body.byLocation.map((g) => g.locationId),
    [assigned.locationId]
  );
  assert.deepEqual(
    res.body.byProduct.map((g) => g.productId),
    [assigned.productId]
  );
  assert.deepEqual(
    res.body.byVariant.map((g) => g.variantId),
    [assigned.variantId]
  );
});

test('responsible unfiltered report excludes distributions at unassigned locations', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 2,
  });
  // Distribution-only at an unassigned location must not leak (nor appear as a
  // negative balance).
  await auth.createDistribution({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 6,
  });

  const { token } = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assigned.locationId],
  });
  const res = await auth.getJson(server.baseUrl, reportUrl(), token);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 2,
    distributedQuantity: 0,
    remainingQuantity: 2,
  });
  assert.deepEqual(
    res.body.byLocation.map((g) => g.locationId),
    [assigned.locationId]
  );
});

test('responsible explicit unassigned location returns 403, assigned succeeds', async () => {
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

test('responsible user with no assignments receives zero totals and empty arrays', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 7,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 2,
  });

  const { token } = await auth.createResponsibleToken(server.baseUrl);
  const res = await auth.getJson(server.baseUrl, reportUrl(), token);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 0,
    distributedQuantity: 0,
    remainingQuantity: 0,
  });
  assert.deepEqual(res.body.byLocation, []);
  assert.deepEqual(res.body.byProduct, []);
  assert.deepEqual(res.body.byVariant, []);
});

// ---------------------------------------------------------------------------
// Aggregation correctness
// ---------------------------------------------------------------------------

test('empty report returns zero totals, empty arrays and exact keys', async () => {
  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [...TOP_KEYS].sort());
  assert.deepEqual(Object.keys(res.body.totals).sort(), [...TOTAL_KEYS].sort());
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 0,
    distributedQuantity: 0,
    remainingQuantity: 0,
  });
  assert.deepEqual(res.body.byLocation, []);
  assert.deepEqual(res.body.byProduct, []);
  assert.deepEqual(res.body.byVariant, []);
});

test('sums multiple collection and distribution rows without multiplication', async () => {
  const fx = await makeFixture();
  const s1 = await auth.createShift({ date: '2026-03-01', locationIds: [fx.locationId] });
  const s2 = await auth.createShift({ date: '2026-03-02', locationIds: [fx.locationId] });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 5,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 3,
    shiftId: s1,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 2,
    shiftId: s2,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 4,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 8,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 10,
    distributedQuantity: 12,
    remainingQuantity: -2,
  });

  assert.equal(res.body.byLocation.length, 1);
  assert.deepEqual(res.body.byLocation[0], {
    locationId: fx.locationId,
    locationName: fx.locationName,
    collectedQuantity: 10,
    distributedQuantity: 12,
    remainingQuantity: -2,
  });

  assert.equal(res.body.byProduct.length, 1);
  assert.deepEqual(res.body.byProduct[0], {
    productId: fx.productId,
    productName: fx.productName,
    category: null,
    collectedQuantity: 10,
    distributedQuantity: 12,
    remainingQuantity: -2,
  });

  assert.equal(res.body.byVariant.length, 1);
  assert.deepEqual(res.body.byVariant[0], {
    variantId: fx.variantId,
    productId: fx.productId,
    productName: fx.productName,
    unitLabel: '1 бр',
    collectedQuantity: 10,
    distributedQuantity: 12,
    remainingQuantity: -2,
  });
});

test('collection-only record has zero distributed and positive remaining', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 5,
  });
  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 5,
    distributedQuantity: 0,
    remainingQuantity: 5,
  });
  assert.equal(res.body.byVariant.length, 1);
  assert.equal(res.body.byVariant[0].distributedQuantity, 0);
});

test('distribution-only record appears with zero collected and negative remaining', async () => {
  const fx = await makeFixture();
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 6,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 0,
    distributedQuantity: 6,
    remainingQuantity: -6,
  });
  assert.equal(res.body.byLocation.length, 1);
  assert.equal(res.body.byLocation[0].collectedQuantity, 0);
  assert.equal(res.body.byLocation[0].remainingQuantity, -6);
  assert.equal(res.body.byVariant[0].collectedQuantity, 0);
  assert.equal(res.body.byVariant[0].remainingQuantity, -6);
});

test('equal collected and distributed quantities produce a visible zero balance', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 4,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 4,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 4,
    distributedQuantity: 4,
    remainingQuantity: 0,
  });
  assert.equal(res.body.byVariant.length, 1);
  assert.equal(res.body.byVariant[0].remainingQuantity, 0);
  assert.equal(res.body.byVariant[0].collectedQuantity, 4);
  assert.equal(res.body.byVariant[0].distributedQuantity, 4);
});

test('pairs with no activity are omitted', async () => {
  const active = await makeFixture();
  await makeFixture(); // no records at all
  await auth.createCollectedQuantity({
    locationId: active.locationId,
    variantId: active.variantId,
    quantity: 3,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.equal(res.body.byLocation.length, 1);
  assert.equal(res.body.byProduct.length, 1);
  assert.equal(res.body.byVariant.length, 1);
  assert.equal(res.body.byLocation[0].locationId, active.locationId);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 3,
    distributedQuantity: 0,
    remainingQuantity: 3,
  });
});

test('totals and summaries agree with seeded data across groupings', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  const v2 = await auth.createVariant({ productId: a.productId, unitLabel: '2 бр' });

  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 4,
  });
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: v2,
    quantity: 6,
  });
  await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 10,
  });
  await auth.createDistribution({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 1,
  });
  await auth.createDistribution({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 20,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 20,
    distributedQuantity: 21,
    remainingQuantity: -1,
  });

  const locById = new Map(res.body.byLocation.map((g) => [g.locationId, g]));
  assert.equal(locById.get(a.locationId).collectedQuantity, 10);
  assert.equal(locById.get(a.locationId).distributedQuantity, 1);
  assert.equal(locById.get(a.locationId).remainingQuantity, 9);
  assert.equal(locById.get(b.locationId).collectedQuantity, 10);
  assert.equal(locById.get(b.locationId).distributedQuantity, 20);
  assert.equal(locById.get(b.locationId).remainingQuantity, -10);

  const prodById = new Map(res.body.byProduct.map((g) => [g.productId, g]));
  assert.equal(prodById.get(a.productId).collectedQuantity, 10);
  assert.equal(prodById.get(a.productId).distributedQuantity, 1);
  assert.equal(prodById.get(b.productId).collectedQuantity, 10);
  assert.equal(prodById.get(b.productId).distributedQuantity, 20);

  const varById = new Map(res.body.byVariant.map((g) => [g.variantId, g]));
  assert.equal(varById.get(a.variantId).remainingQuantity, 3);
  assert.equal(varById.get(v2).collectedQuantity, 6);
  assert.equal(varById.get(v2).remainingQuantity, 6);
  assert.equal(varById.get(b.variantId).remainingQuantity, -10);
});

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

test('filters by locationId', async () => {
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

  const res = await auth.getJson(
    server.baseUrl,
    reportUrl({ locationId: a.locationId }),
    adminToken
  );
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 10,
    distributedQuantity: 0,
    remainingQuantity: 10,
  });
  assert.deepEqual(
    res.body.byLocation.map((g) => g.locationId),
    [a.locationId]
  );
});

test('filters by productId', async () => {
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

  const res = await auth.getJson(
    server.baseUrl,
    reportUrl({ productId: b.productId }),
    adminToken
  );
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 20,
    distributedQuantity: 0,
    remainingQuantity: 20,
  });
  assert.deepEqual(
    res.body.byProduct.map((g) => g.productId),
    [b.productId]
  );
});

test('filters by variantId', async () => {
  const fx = await makeFixture();
  const v2 = await auth.createVariant({ productId: fx.productId, unitLabel: '2 бр' });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 3,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: v2,
    quantity: 5,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: v2,
    quantity: 2,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl({ variantId: v2 }), adminToken);
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 5,
    distributedQuantity: 2,
    remainingQuantity: 3,
  });
  assert.equal(res.body.byVariant.length, 1);
  assert.equal(res.body.byVariant[0].variantId, v2);
  assert.equal(res.body.byVariant[0].unitLabel, '2 бр');
});

test('filters apply consistently to both collections and distributions', async () => {
  const a = await makeFixture();
  const b = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 3,
  });
  await auth.createDistribution({
    locationId: a.locationId,
    variantId: a.variantId,
    quantity: 2,
  });
  await auth.createCollectedQuantity({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 5,
  });
  await auth.createDistribution({
    locationId: b.locationId,
    variantId: b.variantId,
    quantity: 7,
  });

  const res = await auth.getJson(
    server.baseUrl,
    reportUrl({ locationId: a.locationId }),
    adminToken
  );
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 3,
    distributedQuantity: 2,
    remainingQuantity: 1,
  });
  assert.equal(res.body.byVariant.length, 1);
});

test('combines location, product and variant filters', async () => {
  const fx = await makeFixture();
  const v2 = await auth.createVariant({ productId: fx.productId, unitLabel: '2 бр' });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 6,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: v2,
    quantity: 9,
  });

  const res = await auth.getJson(
    server.baseUrl,
    reportUrl({
      locationId: fx.locationId,
      productId: fx.productId,
      variantId: fx.variantId,
    }),
    adminToken
  );
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 6,
    distributedQuantity: 0,
    remainingQuantity: 6,
  });
  assert.equal(res.body.byVariant.length, 1);
  assert.equal(res.body.byVariant[0].variantId, fx.variantId);
});

test('responsible scope combines with product and date filters', async () => {
  const assigned = await makeFixture();
  const other = await makeFixture();
  const inWindow = await auth.createShift({
    date: '2026-06-01',
    locationIds: [assigned.locationId],
  });
  const outWindow = await auth.createShift({
    date: '2026-01-01',
    locationIds: [assigned.locationId],
  });
  await auth.createCollectedQuantity({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 7,
    shiftId: inWindow,
  });
  await auth.createCollectedQuantity({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 100,
    shiftId: outWindow,
  });
  const otherShift = await auth.createShift({
    date: '2026-06-01',
    locationIds: [other.locationId],
  });
  await auth.createCollectedQuantity({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 50,
    shiftId: otherShift,
  });
  await auth.createDistribution({
    locationId: assigned.locationId,
    variantId: assigned.variantId,
    quantity: 2,
    distributionDate: '2026-06-02',
  });
  await auth.createDistribution({
    locationId: other.locationId,
    variantId: other.variantId,
    quantity: 9,
    distributionDate: '2026-06-02',
  });

  const { token } = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assigned.locationId],
  });
  const res = await auth.getJson(
    server.baseUrl,
    reportUrl({
      productId: assigned.productId,
      dateFrom: '2026-06-01',
      dateTo: '2026-06-30',
    }),
    token
  );
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 7,
    distributedQuantity: 2,
    remainingQuantity: 5,
  });
  assert.deepEqual(
    res.body.byLocation.map((g) => g.locationId),
    [assigned.locationId]
  );
});

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

test('date filters are inclusive on both boundaries', async () => {
  const fx = await makeFixture();
  const sLow = await auth.createShift({ date: '2026-04-01', locationIds: [fx.locationId] });
  const sHigh = await auth.createShift({ date: '2026-04-05', locationIds: [fx.locationId] });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 2,
    shiftId: sLow,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 4,
    shiftId: sHigh,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 3,
    distributionDate: '2026-04-01',
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 5,
    distributionDate: '2026-04-05',
  });

  const full = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-04-01', dateTo: '2026-04-05' }),
    adminToken
  );
  assert.deepEqual(full.body.totals, {
    collectedQuantity: 6,
    distributedQuantity: 8,
    remainingQuantity: -2,
  });

  const inside = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-04-02', dateTo: '2026-04-04' }),
    adminToken
  );
  assert.deepEqual(inside.body.totals, {
    collectedQuantity: 0,
    distributedQuantity: 0,
    remainingQuantity: 0,
  });

  const fromOnly = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-04-02' }),
    adminToken
  );
  assert.deepEqual(fromOnly.body.totals, {
    collectedQuantity: 4,
    distributedQuantity: 5,
    remainingQuantity: -1,
  });

  const toOnly = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateTo: '2026-04-04' }),
    adminToken
  );
  assert.deepEqual(toOnly.body.totals, {
    collectedQuantity: 2,
    distributedQuantity: 3,
    remainingQuantity: -1,
  });
});

test('any date filter excludes legacy unlinked collections', async () => {
  const fx = await makeFixture();
  const shift = await auth.createShift({ date: '2026-05-01', locationIds: [fx.locationId] });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 8,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 3,
    shiftId: shift,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 1,
    distributionDate: '2026-05-01',
  });

  const unfiltered = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(unfiltered.body.totals, {
    collectedQuantity: 11,
    distributedQuantity: 1,
    remainingQuantity: 10,
  });

  const from = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-01-01' }),
    adminToken
  );
  assert.deepEqual(from.body.totals, {
    collectedQuantity: 3,
    distributedQuantity: 1,
    remainingQuantity: 2,
  });

  const to = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateTo: '2026-12-31' }),
    adminToken
  );
  assert.deepEqual(to.body.totals, {
    collectedQuantity: 3,
    distributedQuantity: 1,
    remainingQuantity: 2,
  });
});

test('date-filtered report is window net flow, not a historical balance', async () => {
  const fx = await makeFixture();
  const before = await auth.createShift({ date: '2026-03-01', locationIds: [fx.locationId] });
  const inWindow = await auth.createShift({ date: '2026-03-10', locationIds: [fx.locationId] });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 10,
    shiftId: before,
  });
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 5,
    shiftId: inWindow,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 7,
    distributionDate: '2026-03-11',
  });

  const res = await auth.getJson(
    server.baseUrl,
    reportUrl({ dateFrom: '2026-03-10', dateTo: '2026-03-11' }),
    adminToken
  );
  // Net flow within the window: only the 2026-03-10 collection counts.
  // A historical balance "as of 2026-03-11" would be 10 + 5 - 7 = 8.
  assert.deepEqual(res.body.totals, {
    collectedQuantity: 5,
    distributedQuantity: 7,
    remainingQuantity: -2,
  });
});

// ---------------------------------------------------------------------------
// Validation and safe response shape
// ---------------------------------------------------------------------------

test('rejects unknown, malformed, duplicate and reversed query parameters', async () => {
  const cases = [
    '/api/reports/inventory?unknown=1',
    '/api/reports/inventory?shiftId=1',
    '/api/reports/inventory?locationId=abc',
    '/api/reports/inventory?locationId=0',
    '/api/reports/inventory?locationId=1.5',
    '/api/reports/inventory?productId=-1',
    '/api/reports/inventory?variantId=0',
    '/api/reports/inventory?dateFrom=2026-02-30',
    '/api/reports/inventory?dateTo=not-a-date',
    '/api/reports/inventory?dateFrom=2026-03-10&dateFrom=2026-03-11',
    '/api/reports/inventory?dateFrom=2026-03-11&dateTo=2026-03-10',
  ];
  for (const path of cases) {
    const res = await auth.getJson(server.baseUrl, path, adminToken);
    assert.equal(res.status, 400, path);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', path);
  }
});

test('every quantity is a JavaScript number and keys are exact', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 4,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 9,
  });

  const res = await auth.getJson(server.baseUrl, reportUrl(), adminToken);
  assert.deepEqual(Object.keys(res.body).sort(), [...TOP_KEYS].sort());
  assert.deepEqual(Object.keys(res.body.totals).sort(), [...TOTAL_KEYS].sort());
  assert.deepEqual(
    Object.keys(res.body.byLocation[0]).sort(),
    [...LOCATION_KEYS].sort()
  );
  assert.deepEqual(
    Object.keys(res.body.byProduct[0]).sort(),
    [...PRODUCT_KEYS].sort()
  );
  assert.deepEqual(
    Object.keys(res.body.byVariant[0]).sort(),
    [...VARIANT_KEYS].sort()
  );

  for (const value of Object.values(res.body.totals)) {
    assert.equal(typeof value, 'number');
  }
  for (const group of res.body.byLocation) {
    assert.equal(typeof group.collectedQuantity, 'number');
    assert.equal(typeof group.distributedQuantity, 'number');
    assert.equal(typeof group.remainingQuantity, 'number');
  }
  for (const group of res.body.byProduct) {
    assert.equal(typeof group.collectedQuantity, 'number');
    assert.equal(typeof group.distributedQuantity, 'number');
    assert.equal(typeof group.remainingQuantity, 'number');
  }
  for (const group of res.body.byVariant) {
    assert.equal(typeof group.collectedQuantity, 'number');
    assert.equal(typeof group.distributedQuantity, 'number');
    assert.equal(typeof group.remainingQuantity, 'number');
  }
});

test('never leaks internal fields', async () => {
  const fx = await makeFixture();
  await auth.createCollectedQuantity({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 2,
  });
  await auth.createDistribution({
    locationId: fx.locationId,
    variantId: fx.variantId,
    quantity: 1,
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
    'distributed_by',
    'distributedBy',
    'distributed_at',
    'distributedAt',
    'phone',
    'firstName',
    'lastName',
    'token',
    'password_hash',
    'collected_quantity_id',
    'distribution_id',
    'shift_id',
  ]) {
    assert.ok(!text.includes(key), key);
  }
});

// ---------------------------------------------------------------------------
// Deterministic ordering
// ---------------------------------------------------------------------------

test('groups are ordered by collected quantity desc, then id asc', async () => {
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
  assert.deepEqual(
    res.body.byLocation.map((g) => g.collectedQuantity),
    [9, 5, 5, 2]
  );
  assert.deepEqual(
    res.body.byProduct.map((g) => g.productId),
    [high.productId, tieA.productId, tieB.productId, low.productId]
  );
  assert.deepEqual(
    res.body.byVariant.map((g) => g.variantId),
    [high.variantId, tieA.variantId, tieB.variantId, low.variantId]
  );
});
