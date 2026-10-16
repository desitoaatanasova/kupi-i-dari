'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SAFE_KEYS = ['id', 'name', 'address', 'isActive'];

let server;

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
});

test('lists locations publicly without a token', async () => {
  await auth.createLocation({ name: 'Пункт А', address: 'ул. Първа 1' });
  const res = await auth.getJson(server.baseUrl, '/api/locations');
  assert.equal(res.status, 200);
  assert.equal(res.body.locations.length, 1);
});

test('returns only active locations', async () => {
  await auth.createLocation({ name: 'Активен', address: 'ул. Жива 1' });
  await auth.createLocation({ name: 'Архив', address: 'ул. Стара 2', isActive: false });

  const res = await auth.getJson(server.baseUrl, '/api/locations');
  assert.equal(res.status, 200);
  assert.equal(res.body.locations.length, 1);
  assert.equal(res.body.locations[0].name, 'Активен');
});

test('orders active locations by name then id', async () => {
  await auth.createLocation({ name: 'Gamma' });
  await auth.createLocation({ name: 'Alpha' });
  await auth.createLocation({ name: 'Beta' });

  const res = await auth.getJson(server.baseUrl, '/api/locations');
  assert.deepEqual(
    res.body.locations.map((location) => location.name),
    ['Alpha', 'Beta', 'Gamma']
  );
});

test('returns an empty list when there are no active locations', async () => {
  const res = await auth.getJson(server.baseUrl, '/api/locations');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.locations, []);
});

test('exposes exactly the safe keys on location detail', async () => {
  const id = await auth.createLocation({ name: 'Детайл', address: 'бул. Централен 5' });
  const res = await auth.getJson(server.baseUrl, `/api/locations/${id}`);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [...SAFE_KEYS].sort());
  assert.equal(res.body.id, id);
  assert.equal(res.body.name, 'Детайл');
  assert.equal(res.body.address, 'бул. Централен 5');
  assert.equal(res.body.isActive, true);
});

test('missing, malformed and archived ids all return 404', async () => {
  const archivedId = await auth.createLocation({
    name: 'Скрит',
    address: 'ул. Тайна 1',
    isActive: false,
  });

  const paths = [
    '/api/locations/99999999',
    '/api/locations/abc',
    '/api/locations/0',
    '/api/locations/-1',
    '/api/locations/1.5',
    `/api/locations/${archivedId}`,
  ];

  for (const path of paths) {
    const res = await auth.getJson(server.baseUrl, path);
    assert.equal(res.status, 404, path);
    assert.equal(res.body.error.code, 'NOT_FOUND', path);
  }
});

test('round-trips Bulgarian text', async () => {
  const name = 'Склад „Надежда“';
  const address = 'ж.к. Люлин, бул. България 12';
  const id = await auth.createLocation({ name, address });

  const res = await auth.getJson(server.baseUrl, `/api/locations/${id}`);
  assert.equal(res.status, 200);
  assert.equal(res.body.name, name);
  assert.equal(res.body.address, address);
});
