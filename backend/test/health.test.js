'use strict';

const { test, after } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const app = require('../src/app');
const { pool } = require('../src/db');

after(async () => {
  await pool.end();
});

test('GET /api/health reports ok with database and timezone', async (t) => {
  await ensureMigrated();

  const server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));

  const { port } = server.address();
  const response = await fetch(`http://127.0.0.1:${port}/api/health`);

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.status, 'ok');
  assert.equal(body.database, 'ok');
  assert.equal(body.timezone, 'Europe/Sofia');
});

test('unknown routes return a structured 404', async (t) => {
  const server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));

  const { port } = server.address();
  const response = await fetch(`http://127.0.0.1:${port}/api/does-not-exist`);

  assert.equal(response.status, 404);
  const body = await response.json();
  assert.equal(body.error.code, 'NOT_FOUND');
});
