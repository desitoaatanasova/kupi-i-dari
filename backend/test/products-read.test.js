'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const PRODUCT_KEYS = ['id', 'name', 'category', 'isActive'];
const VARIANT_KEYS = ['id', 'productId', 'unitLabel', 'unitValue', 'isActive'];

let server;

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
});

test('lists products publicly without a token', async () => {
  await auth.createProduct({ name: 'Ориз', category: 'Храни' });
  const res = await auth.getJson(server.baseUrl, '/api/products');
  assert.equal(res.status, 200);
  assert.equal(res.body.products.length, 1);
});

test('returns only active products', async () => {
  await auth.createProduct({ name: 'Активен', category: 'Храни' });
  await auth.createProduct({ name: 'Архив', category: 'Храни', isActive: false });

  const res = await auth.getJson(server.baseUrl, '/api/products');
  assert.equal(res.status, 200);
  assert.equal(res.body.products.length, 1);
  assert.equal(res.body.products[0].name, 'Активен');
});

test('orders active products by name then id', async () => {
  await auth.createProduct({ name: 'Gamma' });
  await auth.createProduct({ name: 'Alpha' });
  await auth.createProduct({ name: 'Beta' });

  const res = await auth.getJson(server.baseUrl, '/api/products');
  assert.deepEqual(
    res.body.products.map((product) => product.name),
    ['Alpha', 'Beta', 'Gamma']
  );
});

test('returns an empty list when there are no active products', async () => {
  const res = await auth.getJson(server.baseUrl, '/api/products');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.products, []);
});

test('exposes exactly the safe keys on product detail', async () => {
  const id = await auth.createProduct({ name: 'Ориз басмати', category: 'Храни' });
  const res = await auth.getJson(server.baseUrl, `/api/products/${id}`);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [...PRODUCT_KEYS].sort());
  assert.equal(res.body.id, id);
  assert.equal(res.body.name, 'Ориз басмати');
  assert.equal(res.body.category, 'Храни');
  assert.equal(res.body.isActive, true);
});

test('serializes a missing category as null', async () => {
  const id = await auth.createProduct({ name: 'Без категория' });
  const res = await auth.getJson(server.baseUrl, `/api/products/${id}`);
  assert.equal(res.status, 200);
  assert.equal(res.body.category, null);
});

test('missing, malformed and archived ids all return 404', async () => {
  const archivedId = await auth.createProduct({ name: 'Скрит', isActive: false });

  const paths = [
    '/api/products/99999999',
    '/api/products/abc',
    '/api/products/0',
    '/api/products/-1',
    '/api/products/1.5',
    `/api/products/${archivedId}`,
  ];

  for (const path of paths) {
    const res = await auth.getJson(server.baseUrl, path);
    assert.equal(res.status, 404, path);
    assert.equal(res.body.error.code, 'NOT_FOUND', path);
  }
});

test('round-trips Bulgarian text', async () => {
  const name = 'Ябълки „Свежест“';
  const category = 'Плодове и зеленчуци';
  const id = await auth.createProduct({ name, category });

  const res = await auth.getJson(server.baseUrl, `/api/products/${id}`);
  assert.equal(res.status, 200);
  assert.equal(res.body.name, name);
  assert.equal(res.body.category, category);
});

test('lists active variants publicly for an active product', async () => {
  const productId = await auth.createProduct({ name: 'Мляко' });
  await auth.createVariant({ productId, unitLabel: '1 л', unitValue: 1 });
  await auth.createVariant({ productId, unitLabel: '2 л', unitValue: 2 });

  const res = await auth.getJson(server.baseUrl, `/api/products/${productId}/variants`);
  assert.equal(res.status, 200);
  assert.equal(res.body.variants.length, 2);
  assert.deepEqual(
    res.body.variants.map((variant) => variant.unitLabel),
    ['1 л', '2 л']
  );
  for (const variant of res.body.variants) {
    assert.deepEqual(Object.keys(variant).sort(), [...VARIANT_KEYS].sort());
  }
  assert.equal(res.body.variants[0].productId, productId);
  assert.equal(res.body.variants[0].isActive, true);
});

test('variant unitValue is a number when set and null when absent', async () => {
  const productId = await auth.createProduct({ name: 'Захар' });
  await auth.createVariant({ productId, unitLabel: 'с пакет', unitValue: 1.5 });
  await auth.createVariant({ productId, unitLabel: 'без размер', unitValue: null });

  const res = await auth.getJson(server.baseUrl, `/api/products/${productId}/variants`);
  const byLabel = Object.fromEntries(
    res.body.variants.map((variant) => [variant.unitLabel, variant.unitValue])
  );
  assert.equal(byLabel['с пакет'], 1.5);
  assert.equal(byLabel['без размер'], null);
});

test('variant list excludes inactive variants', async () => {
  const productId = await auth.createProduct({ name: 'Брашно' });
  await auth.createVariant({ productId, unitLabel: 'активна' });
  await auth.createVariant({ productId, unitLabel: 'архивна', isActive: false });

  const res = await auth.getJson(server.baseUrl, `/api/products/${productId}/variants`);
  assert.equal(res.status, 200);
  assert.deepEqual(
    res.body.variants.map((variant) => variant.unitLabel),
    ['активна']
  );
});

test('variant list returns 404 for malformed, missing or archived products', async () => {
  const archivedId = await auth.createProduct({ name: 'Архив', isActive: false });

  const paths = [
    '/api/products/abc/variants',
    '/api/products/0/variants',
    '/api/products/99999999/variants',
    `/api/products/${archivedId}/variants`,
  ];

  for (const path of paths) {
    const res = await auth.getJson(server.baseUrl, path);
    assert.equal(res.status, 404, path);
    assert.equal(res.body.error.code, 'NOT_FOUND', path);
  }
});
