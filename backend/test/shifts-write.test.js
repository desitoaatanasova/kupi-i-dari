'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const SHIFT_KEYS = ['id', 'title', 'date', 'startTime', 'endTime', 'status'];
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

async function makeLocation() {
  return auth.createLocation({ name: uniq('Локация') });
}

function validBody(overrides = {}) {
  return {
    date: '2026-11-01',
    startTime: '09:00',
    endTime: '13:00',
    locationIds: [],
    ...overrides,
  };
}

test('shift writes require authentication', async () => {
  const locationId = await makeLocation();

  const created = await auth.postJson(server.baseUrl, '/api/shifts', validBody({ locationIds: [locationId] }));
  assert.equal(created.status, 401);

  const shiftId = await auth.createShift({ locationIds: [locationId] });
  const updated = await auth.patchJson(server.baseUrl, `/api/shifts/${shiftId}`, {
    title: 'X',
  });
  assert.equal(updated.status, 401);
});

test('volunteers and responsibles cannot create or update shifts', async () => {
  const locationId = await makeLocation();
  const shiftId = await auth.createShift({ locationIds: [locationId] });
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const responsible = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [locationId],
  });

  for (const token of [volunteer.token, responsible.token]) {
    const created = await auth.postJson(
      server.baseUrl,
      '/api/shifts',
      validBody({ locationIds: [locationId] }),
      token
    );
    assert.equal(created.status, 403);
    assert.equal(created.body.error.code, 'FORBIDDEN');

    const updated = await auth.patchJson(
      server.baseUrl,
      `/api/shifts/${shiftId}`,
      { title: 'X' },
      token
    );
    assert.equal(updated.status, 403);

    const status = await auth.patchJson(
      server.baseUrl,
      `/api/shifts/${shiftId}/status`,
      { status: 'OPEN' },
      token
    );
    assert.equal(status.status, 403);
  }
});

test('admin creates a DRAFT shift with its locations and the exact safe shape', async () => {
  const locationId = await makeLocation();

  const res = await auth.postJson(
    server.baseUrl,
    '/api/shifts',
    validBody({ title: '  Съботен   сбор ', locationIds: [locationId] }),
    adminToken
  );

  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.deepEqual(
    Object.keys(res.body).sort(),
    [...SHIFT_KEYS, 'locations'].sort()
  );
  assert.equal(res.body.title, 'Съботен сбор');
  assert.equal(res.body.date, '2026-11-01');
  assert.equal(res.body.startTime, '09:00:00');
  assert.equal(res.body.endTime, '13:00:00');
  assert.equal(res.body.status, 'DRAFT');
  assert.equal(res.body.locations.length, 1);
  assert.deepEqual(Object.keys(res.body.locations[0]).sort(), [...LOCATION_KEYS].sort());
  assert.equal(res.body.locations[0].id, locationId);

  for (const key of ['createdBy', 'created_by', 'createdAt', 'created_at', 'updatedAt']) {
    assert.ok(!(key in res.body), key);
  }
});

test('title is optional and defaults to null', async () => {
  const locationId = await makeLocation();
  const res = await auth.postJson(
    server.baseUrl,
    '/api/shifts',
    validBody({ locationIds: [locationId] }),
    adminToken
  );
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(res.body.title, null);
});

test('shift creation requires at least one location', async () => {
  const res = await auth.postJson(
    server.baseUrl,
    '/api/shifts',
    validBody({ locationIds: [] }),
    adminToken
  );
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('rejects invalid dates, times and unknown fields', async () => {
  const locationId = await makeLocation();

  const cases = [
    validBody({ locationIds: [locationId], date: '2026-02-30' }),
    validBody({ locationIds: [locationId], date: '01-11-2026' }),
    validBody({ locationIds: [locationId], startTime: '25:00' }),
    validBody({ locationIds: [locationId], startTime: '9:00' }),
    validBody({ locationIds: [locationId], endTime: '13:60' }),
    validBody({ locationIds: [locationId], title: 'A'.repeat(121) }),
    { ...validBody({ locationIds: [locationId] }), extra: true },
    { ...validBody({ locationIds: [locationId] }), locationIds: [] },
  ];

  for (const body of cases) {
    const res = await auth.postJson(server.baseUrl, '/api/shifts', body, adminToken);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});

test('endTime must be strictly later than startTime', async () => {
  const locationId = await makeLocation();

  for (const [startTime, endTime] of [
    ['13:00', '13:00'],
    ['14:00', '13:00'],
  ]) {
    const res = await auth.postJson(
      server.baseUrl,
      '/api/shifts',
      validBody({ locationIds: [locationId], startTime, endTime }),
      adminToken
    );
    assert.equal(res.status, 400, `${startTime}-${endTime}`);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR');
  }
});

test('rejects missing or inactive locations without partial writes', async () => {
  const activeId = await makeLocation();
  const inactiveId = await auth.createLocation({ name: uniq('Архивна'), isActive: false });

  const before = await auth.getJson(server.baseUrl, '/api/shifts', adminToken);

  for (const locationIds of [[99999999], [inactiveId]]) {
    const res = await auth.postJson(
      server.baseUrl,
      '/api/shifts',
      validBody({ locationIds }),
      adminToken
    );
    assert.equal(res.status, 400, JSON.stringify(locationIds));
    assert.equal(res.body.error.code, 'INVALID_LOCATION');
  }

  const after = await auth.getJson(server.baseUrl, '/api/shifts', adminToken);
  assert.equal(after.body.shifts.length, before.body.shifts.length);
});

test('admin updates title/date/times while DRAFT or OPEN', async () => {
  const locationId = await makeLocation();
  const shiftId = await auth.createShift({ locationIds: [locationId], status: 'OPEN' });

  const res = await auth.patchJson(
    server.baseUrl,
    `/api/shifts/${shiftId}`,
    { title: '  Обновено ', date: '2026-12-05', startTime: '10:15', endTime: '14:45' },
    adminToken
  );
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(Object.keys(res.body).sort(), [...SHIFT_KEYS].sort());
  assert.equal(res.body.title, 'Обновено');
  assert.equal(res.body.date, '2026-12-05');
  assert.equal(res.body.startTime, '10:15:00');
  assert.equal(res.body.endTime, '14:45:00');
  assert.equal(res.body.status, 'OPEN');
});

test('update requires at least one field', async () => {
  const locationId = await makeLocation();
  const shiftId = await auth.createShift({ locationIds: [locationId] });

  const res = await auth.patchJson(server.baseUrl, `/api/shifts/${shiftId}`, {}, adminToken);
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'VALIDATION_ERROR');
});

test('update validates the combined times against the stored values', async () => {
  const locationId = await makeLocation();
  const shiftId = await auth.createShift({
    locationIds: [locationId],
    startTime: '09:00:00',
    endTime: '13:00:00',
  });

  const bad = await auth.patchJson(
    server.baseUrl,
    `/api/shifts/${shiftId}`,
    { endTime: '08:00' },
    adminToken
  );
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error.code, 'VALIDATION_ERROR');

  const ok = await auth.patchJson(
    server.baseUrl,
    `/api/shifts/${shiftId}`,
    { startTime: '08:00' },
    adminToken
  );
  assert.equal(ok.status, 200);
  assert.equal(ok.body.startTime, '08:00:00');
  assert.equal(ok.body.endTime, '13:00:00');
});

test('closed and cancelled shifts are not editable', async () => {
  const locationId = await makeLocation();

  for (const status of ['CLOSED', 'CANCELLED']) {
    const shiftId = await auth.createShift({ locationIds: [locationId], status });
    const res = await auth.patchJson(
      server.baseUrl,
      `/api/shifts/${shiftId}`,
      { title: 'X' },
      adminToken
    );
    assert.equal(res.status, 409, status);
    assert.equal(res.body.error.code, 'SHIFT_NOT_EDITABLE');
  }
});

test('update returns 404 for a missing shift', async () => {
  const res = await auth.patchJson(
    server.baseUrl,
    '/api/shifts/99999999',
    { title: 'X' },
    adminToken
  );
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});
