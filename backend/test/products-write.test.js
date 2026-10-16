'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const PRODUCT_KEYS = ['id', 'name', 'category', 'isActive'];
const BASE = 883100000;

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

const create = (body, token = adminToken) =>
  auth.postJson(server.baseUrl, '/api/products', body, token);

test('create requires authentication', async () => {
  const res = await auth.postJson(server.baseUrl, '/api/products', { name: 'X' });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('create forbids non-admin staff', async () => {
  await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(1));
  const res = await auth.postJson(server.baseUrl, '/api/products', { name: 'Нов' }, token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('creates a product with a safe object and normalises the name', async () => {
  const res = await create({ name: '  Ориз   басмати  ' });
  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(res.body).sort(), [...PRODUCT_KEYS].sort());
  assert.equal(res.body.name, 'Ориз басмати');
  assert.equal(res.body.category, null);
  assert.equal(res.body.isActive, true);
});

test('creates a product with a category', async () => {
  const res = await create({ name: 'Леща', category: '  Храни  ' });
  assert.equal(res.status, 201);
  assert.equal(res.body.category, 'Храни');
});

test('rejects invalid creation payloads', async () => {
  const cases = [
    {},
    { name: '' },
    { name: '   ' },
    { name: 'A'.repeat(121) },
    { name: 'Име', category: '' },
    { name: 'Име', category: 'A'.repeat(81) },
    { name: 5 },
    { name: 'Име', category: { a: 1 } },
    { name: 'Име', extra: 'x' },
  ];

  for (const body of cases) {
    const res = await create(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('rejects a duplicate name including case variants with 409', async () => {
  const first = await create({ name: 'Уникален' });
  assert.equal(first.status, 201);

  const duplicate = await create({ name: 'уникален' });
  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.body.error.code, 'NAME_TAKEN');
});

test('a product name stays reserved after archiving', async () => {
  const id = await auth.createProduct({ name: 'Резервирано', isActive: false });
  const res = await create({ name: 'Резервирано' });
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'NAME_TAKEN');
  assert.ok(id > 0);
});

test('product writes require authentication', async () => {
  const id = await auth.createProduct({ name: 'Точка' });
  const update = await auth.patchJson(server.baseUrl, `/api/products/${id}`, { name: 'Ново' });
  assert.equal(update.status, 401);

  const status = await auth.patchJson(server.baseUrl, `/api/products/${id}/status`, {
    isActive: false,
  });
  assert.equal(status.status, 401);
});

test('product writes forbid non-admin staff', async () => {
  const id = await auth.createProduct({ name: 'Точка' });
  await auth.createUser({ phone: phone(1), role: 'RESPONSIBLE', password: auth.TEST_PASSWORD });
  const token = await loginStaff(phone(1));

  const update = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}`,
    { name: 'Ново' },
    token
  );
  assert.equal(update.status, 403);
  assert.equal(update.body.error.code, 'FORBIDDEN');
});

test('partial update changes only the supplied field', async () => {
  const id = await auth.createProduct({ name: 'Старо име', category: 'Стара' });

  const nameOnly = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}`,
    { name: 'Ново име' },
    adminToken
  );
  assert.equal(nameOnly.status, 200);
  assert.equal(nameOnly.body.name, 'Ново име');
  assert.equal(nameOnly.body.category, 'Стара');
  assert.deepEqual(Object.keys(nameOnly.body).sort(), [...PRODUCT_KEYS].sort());

  const categoryOnly = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}`,
    { category: 'Нова' },
    adminToken
  );
  assert.equal(categoryOnly.status, 200);
  assert.equal(categoryOnly.body.name, 'Ново име');
  assert.equal(categoryOnly.body.category, 'Нова');
});

test('clearing a category with null is persisted', async () => {
  const id = await auth.createProduct({ name: 'Изчисти', category: 'Храни' });
  const res = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}`,
    { category: null },
    adminToken
  );
  assert.equal(res.status, 200);
  assert.equal(res.body.category, null);
});

test('rejects empty, unknown, malformed and oversized updates', async () => {
  const id = await auth.createProduct({ name: 'Валидна' });
  const cases = [
    { body: {}, path: `/api/products/${id}` },
    { body: { extra: 'x' }, path: `/api/products/${id}` },
    { body: { name: '' }, path: `/api/products/${id}` },
    { body: { name: 'A'.repeat(121) }, path: `/api/products/${id}` },
    { body: { category: 'A'.repeat(81) }, path: `/api/products/${id}` },
    { body: { name: 'Ново' }, path: '/api/products/abc' },
    { body: { name: 'Ново' }, path: '/api/products/0' },
  ];

  for (const { body, path } of cases) {
    const res = await auth.patchJson(server.baseUrl, path, body, adminToken);
    assert.equal(res.status, 400, path);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', path);
  }
});

test('updating a missing or archived product returns 404', async () => {
  const archivedId = await auth.createProduct({ name: 'Архивирана', isActive: false });

  const missing = await auth.patchJson(
    server.baseUrl,
    '/api/products/99999999',
    { name: 'Ново' },
    adminToken
  );
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');

  const archived = await auth.patchJson(
    server.baseUrl,
    `/api/products/${archivedId}`,
    { name: 'Ново' },
    adminToken
  );
  assert.equal(archived.status, 404);
  assert.equal(archived.body.error.code, 'NOT_FOUND');
});

test('rejects a duplicate name on update with 409', async () => {
  await auth.createProduct({ name: 'Първа' });
  const secondId = await auth.createProduct({ name: 'Втора' });

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/products/${secondId}`,
    { name: 'ПЪРВА' },
    adminToken
  );
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'NAME_TAKEN');
});

test('archives and reactivates a product', async () => {
  const id = await auth.createProduct({ name: 'Статус' });

  const archived = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}/status`,
    { isActive: false },
    adminToken
  );
  assert.equal(archived.status, 200);
  assert.equal(archived.body.isActive, false);
  assert.deepEqual(Object.keys(archived.body).sort(), [...PRODUCT_KEYS].sort());

  const reactivated = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}/status`,
    { isActive: true },
    adminToken
  );
  assert.equal(reactivated.status, 200);
  assert.equal(reactivated.body.isActive, true);
});

test('repeating a status change is idempotent', async () => {
  const id = await auth.createProduct({ name: 'Идемпотент' });

  const first = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}/status`,
    { isActive: false },
    adminToken
  );
  assert.equal(first.status, 200);
  assert.equal(first.body.isActive, false);

  const second = await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}/status`,
    { isActive: false },
    adminToken
  );
  assert.equal(second.status, 200);
  assert.equal(second.body.isActive, false);

  const [rows] = await auth.pool.query(
    'SELECT is_active FROM products WHERE product_id = ?',
    [id]
  );
  assert.equal(Number(rows[0].is_active), 0);
});

test('rejects malformed ids and invalid status bodies', async () => {
  const id = await auth.createProduct({ name: 'Валидна' });

  for (const badId of ['abc', '0', '-1', '1.5']) {
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/products/${badId}/status`,
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
      `/api/products/${id}/status`,
      body,
      adminToken
    );
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }
});

test('status change on a missing product returns 404', async () => {
  const res = await auth.patchJson(
    server.baseUrl,
    '/api/products/99999999/status',
    { isActive: false },
    adminToken
  );
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});

test('archiving never hard-deletes the row and leaves variants untouched', async () => {
  const id = await auth.createProduct({ name: 'Живее' });
  const variantId = await auth.createVariant({ productId: id, unitLabel: '1 бр' });

  await auth.patchJson(
    server.baseUrl,
    `/api/products/${id}/status`,
    { isActive: false },
    adminToken
  );

  const [productRows] = await auth.pool.query(
    'SELECT product_id FROM products WHERE product_id = ?',
    [id]
  );
  assert.equal(productRows.length, 1);

  const [variantRows] = await auth.pool.query(
    'SELECT is_active FROM product_variants WHERE variant_id = ?',
    [variantId]
  );
  assert.equal(variantRows.length, 1);
  assert.equal(Number(variantRows[0].is_active), 1);
});
