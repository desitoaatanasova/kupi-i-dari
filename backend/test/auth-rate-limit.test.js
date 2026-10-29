'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

// Load the shared test env first, then tighten the auth limits for this file.
require('./helpers/env');
process.env.AUTH_RATE_LIMIT_WINDOW_MS = '600000';
process.env.AUTH_RATE_LIMIT_MAX = '3';
process.env.AUTH_VOLUNTEER_RATE_LIMIT_MAX = '2';

const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const LOGIN_PHONE = '+359884000111';
const VOL_PHONE = '+359884000222';
const REGISTER_PHONE = '+359884000333';
const VOL_LOGIN_PHONE = '+359884000444';

let server;

before(async () => {
  await ensureMigrated();
  await auth.cleanUsers();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanUsers();
  await auth.pool.end();
});

test('staff login limiter returns a structured 429 after the max', async () => {
  const statuses = [];
  for (let i = 0; i < 4; i += 1) {
    const res = await auth.postJson(server.baseUrl, '/api/auth/login', {
      phone: LOGIN_PHONE,
      password: 'wrong-password',
    });
    statuses.push(res.status);
    if (i === 3) {
      assert.equal(res.status, 429);
      assert.deepEqual(res.body, {
        error: {
          code: 'RATE_LIMITED',
          message: 'Too many requests. Please try again later.',
        },
      });
    }
  }
  assert.deepEqual(statuses.slice(0, 3), [401, 401, 401]);
});

test('volunteer limiter returns a structured 429 after the max', async () => {
  const statuses = [];
  for (let i = 0; i < 3; i += 1) {
    const res = await auth.postJson(server.baseUrl, '/api/auth/volunteer', {
      firstName: 'Име',
      lastName: 'Фамилия',
      phone: VOL_PHONE,
    });
    statuses.push(res.status);
    if (i === 2) {
      assert.equal(res.status, 429);
      assert.equal(res.body.error.code, 'RATE_LIMITED');
    }
  }
  assert.deepEqual(statuses.slice(0, 2), [200, 200]);
});

test('registration limiter returns a structured 429 after the max', async () => {
  const statuses = [];
  for (let i = 0; i < 3; i += 1) {
    const res = await auth.postJson(server.baseUrl, '/api/auth/register', {
      firstName: 'Име',
      lastName: 'Фамилия',
      phone: REGISTER_PHONE,
      role: 'VOLUNTEER',
    });
    statuses.push(res.status);
    if (i === 2) {
      assert.equal(res.status, 429);
      assert.equal(res.body.error.code, 'RATE_LIMITED');
    }
  }
  assert.deepEqual(statuses.slice(0, 2), [201, 409]);
});

test('strict volunteer login limiter returns a structured 429 after the max', async () => {
  await auth.createUser({
    phone: VOL_LOGIN_PHONE,
    firstName: 'Име',
    lastName: 'Фамилия',
    role: 'VOLUNTEER',
  });

  const statuses = [];
  for (let i = 0; i < 3; i += 1) {
    const res = await auth.postJson(
      server.baseUrl,
      '/api/auth/volunteer/login',
      {
        firstName: 'Име',
        lastName: 'Фамилия',
        phone: VOL_LOGIN_PHONE,
      }
    );
    statuses.push(res.status);
    if (i === 2) {
      assert.equal(res.status, 429);
      assert.equal(res.body.error.code, 'RATE_LIMITED');
    }
  }
  assert.deepEqual(statuses.slice(0, 2), [200, 200]);
});
