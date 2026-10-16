'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const VARIANT_KEYS = ['id', 'productId', 'unitLabel', 'unitValue', 'isActive'];
const BASE = 883200000;

let server;
let adminToken;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanProducts();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanProducts();
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

function createVariant(productId, body, token = adminToken) {
  return auth.postJson(server.baseUrl, `/api/products/${productId}/variants`, body, token);
}

function updateVariant(productId, variantId, body, token = adminToken) {
  return auth.patchJson(
    server.baseUrl,
    `/api/products/${productId}/variants/${variantId}`,
    body,
    token
  );
}

function setVariantStatus(productId, variantId, body, token = adminToken) {
  return auth.patchJson(
    server.baseUrl,
    `/api/products/${productId}/variants/${variantId}/status`,
    body,
    token
  );
}

test('variant write routes require authentication', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });

  const created = await createVariant(productId, { unitLabel: '2 л' }, null);
  assert.equal(created.status, 401);
  assert.equal(created.body.error.code, 'UNAUTHORIZED');

  const updated = await updateVariant(productId, variantId, { unitLabel: '3 л' }, null);
  assert.equal(updated.status, 401);

  const status = await setVariantStatus(productId, variantId, { isActive: false }, null);
  assert.equal(status.status, 401);
});

test('variant write routes forbid non-admin staff', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });
  await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(1));

  const created = await createVariant(productId, { unitLabel: '2 л' }, token);
  assert.equal(created.status, 403);
  assert.equal(created.body.error.code, 'FORBIDDEN');

  const updated = await updateVariant(productId, variantId, { unitLabel: '3 л' }, token);
  assert.equal(updated.status, 403);

  const status = await setVariantStatus(productId, variantId, { isActive: false }, token);
  assert.equal(status.status, 403);
});

test('creates a variant with a safe object and normalized label', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const res = await createVariant(productId, { unitLabel: '  1   л  ', unitValue: 1 });

  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(res.body).sort(), [...VARIANT_KEYS].sort());
  assert.equal(res.body.productId, productId);
  assert.equal(res.body.unitLabel, '1 л');
  assert.equal(res.body.unitValue, 1);
  assert.equal(res.body.isActive, true);
});

test('creates a variant without a unit value', async () => {
  const productId = await auth.createProduct({ name: 'Яйца' });
  const res = await createVariant(productId, { unitLabel: 'кутия' });
  assert.equal(res.status, 201);
  assert.equal(res.body.unitValue, null);
});

test('rejects creating a variant for a malformed, missing or archived product', async () => {
  const archivedId = await auth.createProduct({ name: 'Архив', isActive: false });

  const malformed = await createVariant('abc', { unitLabel: '1 л' });
  assert.equal(malformed.status, 400);
  assert.equal(malformed.body.error.code, 'VALIDATION_ERROR');

  for (const productId of [99999999, archivedId]) {
    const res = await createVariant(productId, { unitLabel: '1 л' });
    assert.equal(res.status, 404, String(productId));
    assert.equal(res.body.error.code, 'NOT_FOUND', String(productId));
  }
});

test('rejects invalid variant creation payloads', async () => {
  const productId = await auth.createProduct({ name: 'Валидна' });
  const cases = [
    {},
    { unitLabel: '' },
    { unitLabel: '   ' },
    { unitLabel: 'A'.repeat(41) },
    { unitLabel: 5 },
    { unitLabel: '1 л', unitValue: -1 },
    { unitLabel: '1 л', unitValue: 1.2345 },
    { unitLabel: '1 л', unitValue: '1' },
    { unitLabel: '1 л', unitValue: true },
    { unitLabel: '1 л', extra: 'x' },
  ];

  for (const body of cases) {
    const res = await createVariant(productId, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('rejects a duplicate unit label within a product', async () => {
  const productId = await auth.createProduct({ name: 'Ориз' });
  const first = await createVariant(productId, { unitLabel: '1 кг' });
  assert.equal(first.status, 201);

  const duplicate = await createVariant(productId, { unitLabel: '1 КГ' });
  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.body.error.code, 'LABEL_TAKEN');
});

test('the same unit label is allowed under a different product', async () => {
  const first = await auth.createProduct({ name: 'Ориз' });
  const second = await auth.createProduct({ name: 'Брашно' });

  assert.equal((await createVariant(first, { unitLabel: '1 кг' })).status, 201);
  assert.equal((await createVariant(second, { unitLabel: '1 кг' })).status, 201);
});

test('partial update changes only the supplied field', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л', unitValue: 1 });

  const labelOnly = await updateVariant(productId, variantId, { unitLabel: '1.5 л' });
  assert.equal(labelOnly.status, 200);
  assert.equal(labelOnly.body.unitLabel, '1.5 л');
  assert.equal(labelOnly.body.unitValue, 1);
  assert.deepEqual(Object.keys(labelOnly.body).sort(), [...VARIANT_KEYS].sort());

  const valueOnly = await updateVariant(productId, variantId, { unitValue: 1.5 });
  assert.equal(valueOnly.status, 200);
  assert.equal(valueOnly.body.unitLabel, '1.5 л');
  assert.equal(valueOnly.body.unitValue, 1.5);
});

test('clearing a unit value with null is persisted', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л', unitValue: 1 });

  const res = await updateVariant(productId, variantId, { unitValue: null });
  assert.equal(res.status, 200);
  assert.equal(res.body.unitValue, null);
});

test('rejects empty, unknown and invalid variant updates', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });

  const cases = [
    {},
    { extra: 'x' },
    { unitLabel: '' },
    { unitLabel: 'A'.repeat(41) },
    { unitValue: -1 },
    { unitValue: 1.2345 },
    { unitValue: 'x' },
  ];

  for (const body of cases) {
    const res = await updateVariant(productId, variantId, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('addressing a variant through the wrong product returns 404', async () => {
  const first = await auth.createProduct({ name: 'Ориз' });
  const second = await auth.createProduct({ name: 'Брашно' });
  const variantId = await auth.createVariant({ productId: first, unitLabel: '1 кг' });

  const update = await updateVariant(second, variantId, { unitLabel: '2 кг' });
  assert.equal(update.status, 404);
  assert.equal(update.body.error.code, 'NOT_FOUND');

  const status = await setVariantStatus(second, variantId, { isActive: false });
  assert.equal(status.status, 404);
  assert.equal(status.body.error.code, 'NOT_FOUND');
});

test('updating a missing or archived variant returns 404', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const archivedVariant = await auth.createVariant({
    productId,
    unitLabel: 'архив',
    isActive: false,
  });

  const missing = await updateVariant(productId, 99999999, { unitLabel: 'x' });
  assert.equal(missing.status, 404);

  const archived = await updateVariant(productId, archivedVariant, { unitLabel: 'x' });
  assert.equal(archived.status, 404);
});

test('updating a variant under an archived product returns 404', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });
  await auth.patchJson(
    server.baseUrl,
    `/api/products/${productId}/status`,
    { isActive: false },
    adminToken
  );

  const res = await updateVariant(productId, variantId, { unitLabel: '2 л' });
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});

test('rejects a duplicate unit label on update with 409', async () => {
  const productId = await auth.createProduct({ name: 'Ориз' });
  await auth.createVariant({ productId, unitLabel: '1 кг' });
  const secondId = await auth.createVariant({ productId, unitLabel: '2 кг' });

  const res = await updateVariant(productId, secondId, { unitLabel: '1 КГ' });
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'LABEL_TAKEN');
});

test('archives and reactivates a variant', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });

  const archived = await setVariantStatus(productId, variantId, { isActive: false });
  assert.equal(archived.status, 200);
  assert.equal(archived.body.isActive, false);
  assert.deepEqual(Object.keys(archived.body).sort(), [...VARIANT_KEYS].sort());

  const reactivated = await setVariantStatus(productId, variantId, { isActive: true });
  assert.equal(reactivated.status, 200);
  assert.equal(reactivated.body.isActive, true);
});

test('repeating a variant status change is idempotent', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });

  await setVariantStatus(productId, variantId, { isActive: false });
  const second = await setVariantStatus(productId, variantId, { isActive: false });
  assert.equal(second.status, 200);
  assert.equal(second.body.isActive, false);

  const [rows] = await auth.pool.query(
    'SELECT is_active FROM product_variants WHERE variant_id = ?',
    [variantId]
  );
  assert.equal(Number(rows[0].is_active), 0);
});

test('variant status works while the parent product is archived', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });
  await auth.patchJson(
    server.baseUrl,
    `/api/products/${productId}/status`,
    { isActive: false },
    adminToken
  );

  const res = await setVariantStatus(productId, variantId, { isActive: false });
  assert.equal(res.status, 200);
  assert.equal(res.body.isActive, false);
});

test('rejects malformed ids and invalid status bodies for variants', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  const variantId = await auth.createVariant({ productId, unitLabel: '1 л' });

  for (const badId of ['abc', '0', '-1', '1.5']) {
    const res = await setVariantStatus(productId, badId, { isActive: false });
    assert.equal(res.status, 400, badId);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', badId);
  }

  const bodyCases = [{}, { isActive: 'yes' }, { isActive: 1 }, { isActive: true, x: 1 }];
  for (const body of bodyCases) {
    const res = await setVariantStatus(productId, variantId, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('status change on a missing variant or product returns 404', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });

  const missingVariant = await setVariantStatus(productId, 99999999, { isActive: false });
  assert.equal(missingVariant.status, 404);
  assert.equal(missingVariant.body.error.code, 'NOT_FOUND');

  const missingProduct = await setVariantStatus(99999999, 1, { isActive: false });
  assert.equal(missingProduct.status, 404);
  assert.equal(missingProduct.body.error.code, 'NOT_FOUND');
});

test('variant responses never leak internal fields', async () => {
  const productId = await auth.createProduct({ name: 'Сигурна' });
  const res = await createVariant(productId, { unitLabel: '1 бр', unitValue: 1 });
  assert.deepEqual(Object.keys(res.body).sort(), [...VARIANT_KEYS].sort());

  const text = JSON.stringify(res.body);
  assert.ok(!text.includes('created_at'));
  assert.ok(!text.includes('updated_at'));
  assert.ok(!text.includes('password'));
  assert.ok(!text.includes('token'));
});
