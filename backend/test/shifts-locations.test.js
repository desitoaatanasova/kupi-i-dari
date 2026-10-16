'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const LOCATION_KEYS = ['id', 'name', 'address', 'isActive'];

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

async function makeLocation(isActive = true) {
  return auth.createLocation({ name: uniq('Локация'), isActive });
}

const put = (shiftId, body, token = adminToken) =>
  auth.putJson(server.baseUrl, `/api/shifts/${shiftId}/locations`, body, token);

test('location replacement requires authentication and ADMIN', async () => {
  const locationId = await makeLocation();
  const shiftId = await auth.createShift({ locationIds: [locationId] });

  const anon = await auth.putJson(
    server.baseUrl,
    `/api/shifts/${shiftId}/locations`,
    { locationIds: [locationId] }
  );
  assert.equal(anon.status, 401);

  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const forbidden = await put(shiftId, { locationIds: [locationId] }, volunteer.token);
  assert.equal(forbidden.status, 403);

  const responsible = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [locationId],
  });
  const responsibleRes = await put(
    shiftId,
    { locationIds: [locationId] },
    responsible.token
  );
  assert.equal(responsibleRes.status, 403);
});

test('admin atomically replaces the location set with the safe location shape', async () => {
  const a = await makeLocation();
  const b = await makeLocation();
  const c = await makeLocation();
  const shiftId = await auth.createShift({ locationIds: [a] });

  const res = await put(shiftId, { locationIds: [b, c] });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(Object.keys(res.body).sort(), ['locations']);
  assert.deepEqual(
    res.body.locations.map((l) => l.id).sort(),
    [b, c].sort()
  );
  assert.deepEqual(Object.keys(res.body.locations[0]).sort(), [...LOCATION_KEYS].sort());

  const detail = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`, adminToken);
  assert.deepEqual(
    detail.body.locations.map((l) => l.id).sort(),
    [b, c].sort()
  );
});

test('replacement rejects malformed, empty, oversized and duplicate id sets', async () => {
  const a = await makeLocation();
  const shiftId = await auth.createShift({ locationIds: [a] });

  const cases = [
    { locationIds: [] },
    { locationIds: [a, a] },
    { locationIds: ['1'] },
    { locationIds: [0] },
    { locationIds: [-1] },
    { locationIds: Array.from({ length: 101 }, (_v, i) => i + 1) },
    { locationIds: a },
    {},
    { locationIds: [a], extra: true },
  ];

  for (const body of cases) {
    const res = await put(shiftId, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});

test('replacement rejects missing and inactive locations without partial writes', async () => {
  const original = await makeLocation();
  const inactive = await makeLocation(false);
  const shiftId = await auth.createShift({ locationIds: [original] });

  for (const locationIds of [[99999999], [inactive], [original, inactive]]) {
    const res = await put(shiftId, { locationIds });
    assert.equal(res.status, 400, JSON.stringify(locationIds));
    assert.equal(res.body.error.code, 'INVALID_LOCATION');
  }

  const detail = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`, adminToken);
  assert.deepEqual(detail.body.locations.map((l) => l.id), [original]);
});

test('replacement returns 404 for a missing shift', async () => {
  const locationId = await makeLocation();
  const res = await put(99999999, { locationIds: [locationId] });
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});

test('replacement is rejected once the shift is CLOSED or CANCELLED', async () => {
  const locationId = await makeLocation();

  for (const status of ['CLOSED', 'CANCELLED']) {
    const shiftId = await auth.createShift({ locationIds: [locationId], status });
    const res = await put(shiftId, { locationIds: [locationId] });
    assert.equal(res.status, 409, status);
    assert.equal(res.body.error.code, 'SHIFT_NOT_EDITABLE');
  }
});

test('malformed shift id returns 400 on the sub-resource route', async () => {
  const locationId = await makeLocation();
  const res = await put('abc', { locationIds: [locationId] });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});
