'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SHIFT_KEYS = ['id', 'title', 'date', 'startTime', 'endTime', 'status'];

let server;
let adminToken;
let nameSeq = 0;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanShifts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanShifts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  adminToken = (await auth.createAdminToken(server.baseUrl)).token;
});

function uniq(prefix) {
  nameSeq += 1;
  return `${prefix} ${nameSeq}`;
}

async function makeShift(status = 'DRAFT') {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  return auth.createShift({ locationIds: [locationId], status });
}

const setStatus = (shiftId, status, token = adminToken) =>
  auth.patchJson(server.baseUrl, `/api/shifts/${shiftId}/status`, { status }, token);

test('status changes require authentication and ADMIN', async () => {
  const shiftId = await makeShift('DRAFT');

  const anon = await auth.patchJson(server.baseUrl, `/api/shifts/${shiftId}/status`, {
    status: 'OPEN',
  });
  assert.equal(anon.status, 401);

  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const forbidden = await setStatus(shiftId, 'OPEN', volunteer.token);
  assert.equal(forbidden.status, 403);

  const responsible = await auth.createResponsibleToken(server.baseUrl);
  const responsibleRes = await setStatus(shiftId, 'OPEN', responsible.token);
  assert.equal(responsibleRes.status, 403);
});

test('allows DRAFT -> OPEN -> CLOSED', async () => {
  const shiftId = await makeShift('DRAFT');

  const opened = await setStatus(shiftId, 'OPEN');
  assert.equal(opened.status, 200, JSON.stringify(opened.body));
  assert.deepEqual(Object.keys(opened.body).sort(), [...SHIFT_KEYS].sort());
  assert.equal(opened.body.status, 'OPEN');

  const closed = await setStatus(shiftId, 'CLOSED');
  assert.equal(closed.status, 200);
  assert.equal(closed.body.status, 'CLOSED');
});

test('allows DRAFT and OPEN -> CANCELLED', async () => {
  const draftId = await makeShift('DRAFT');
  const draftCancelled = await setStatus(draftId, 'CANCELLED');
  assert.equal(draftCancelled.status, 200);
  assert.equal(draftCancelled.body.status, 'CANCELLED');

  const openId = await makeShift('OPEN');
  const openCancelled = await setStatus(openId, 'CANCELLED');
  assert.equal(openCancelled.status, 200);
  assert.equal(openCancelled.body.status, 'CANCELLED');
});

test('repeating the current status is an idempotent 200', async () => {
  for (const status of ['DRAFT', 'OPEN', 'CLOSED', 'CANCELLED']) {
    const shiftId = await makeShift(status);
    const res = await setStatus(shiftId, status);
    assert.equal(res.status, 200, status);
    assert.equal(res.body.status, status);
  }
});

test('rejects invalid status transitions with 409', async () => {
  const cases = [
    ['DRAFT', 'CLOSED'],
    ['CLOSED', 'OPEN'],
    ['CLOSED', 'CANCELLED'],
    ['CANCELLED', 'OPEN'],
    ['CANCELLED', 'CLOSED'],
  ];

  for (const [from, to] of cases) {
    const shiftId = await makeShift(from);
    const res = await setStatus(shiftId, to);
    assert.equal(res.status, 409, `${from}->${to}`);
    assert.equal(res.body.error.code, 'INVALID_STATUS_TRANSITION');
  }
});

test('treats DRAFT as an invalid transition from OPEN and rejects other invalid values', async () => {
  const shiftId = await makeShift('OPEN');

  const draft = await setStatus(shiftId, 'DRAFT');
  assert.equal(draft.status, 409);
  assert.equal(draft.body.error.code, 'INVALID_STATUS_TRANSITION');

  for (const status of ['open', 'UNKNOWN', '', 5, null]) {
    const res = await setStatus(shiftId, status);
    assert.equal(res.status, 400, JSON.stringify(status));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});

test('missing shift returns 404 and malformed id returns 400', async () => {
  const missing = await setStatus(99999999, 'OPEN');
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');

  const malformed = await setStatus('abc', 'OPEN');
  assert.equal(malformed.status, 400);
  assert.equal(malformed.body.error.code, 'VALIDATION_ERROR');
});
