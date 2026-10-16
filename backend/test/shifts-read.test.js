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

test('shift reads require authentication', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await auth.createShift({ locationIds: [locationId] });

  const list = await auth.getJson(server.baseUrl, '/api/shifts');
  assert.equal(list.status, 401);

  const detail = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`);
  assert.equal(detail.status, 401);
});

test('lists shifts with the exact safe shape, ordered by date then start time', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const later = await auth.createShift({ locationIds: [locationId], date: '2026-11-10', startTime: '10:00:00' });
  const earlier = await auth.createShift({ locationIds: [locationId], date: '2026-11-05', startTime: '12:00:00' });
  const sameDayEarlier = await auth.createShift({ locationIds: [locationId], date: '2026-11-05', startTime: '08:00:00' });

  const res = await auth.getJson(server.baseUrl, '/api/shifts', adminToken);
  assert.equal(res.status, 200);
  assert.deepEqual(
    res.body.shifts.map((s) => s.id),
    [sameDayEarlier, earlier, later]
  );
  assert.deepEqual(Object.keys(res.body.shifts[0]).sort(), [...SHIFT_KEYS].sort());
});

test('staff see DRAFT shifts but volunteers do not', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const draftId = await auth.createShift({ locationIds: [locationId], status: 'DRAFT' });
  const openId = await auth.createShift({ locationIds: [locationId], status: 'OPEN' });

  const staff = await auth.getJson(server.baseUrl, '/api/shifts', adminToken);
  assert.deepEqual(
    staff.body.shifts.map((s) => s.id).sort(),
    [draftId, openId].sort()
  );

  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const list = await auth.getJson(server.baseUrl, '/api/shifts', volunteer.token);
  assert.equal(list.status, 200);
  assert.deepEqual(
    list.body.shifts.map((s) => s.id),
    [openId]
  );

  const draftDetail = await auth.getJson(
    server.baseUrl,
    `/api/shifts/${draftId}`,
    volunteer.token
  );
  assert.equal(draftDetail.status, 404);
  assert.equal(draftDetail.body.error.code, 'NOT_FOUND');

  const openDetail = await auth.getJson(
    server.baseUrl,
    `/api/shifts/${openId}`,
    volunteer.token
  );
  assert.equal(openDetail.status, 200);
});

test('shift detail includes its locations and the caller registration status', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await auth.createShift({ locationIds: [locationId], status: 'OPEN' });

  const staff = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`, adminToken);
  assert.equal(staff.status, 200);
  assert.deepEqual(
    Object.keys(staff.body).sort(),
    [...SHIFT_KEYS, 'locations', 'myRegistration'].sort()
  );
  assert.equal(staff.body.myRegistration, null);
  assert.equal(staff.body.locations.length, 1);
  assert.deepEqual(Object.keys(staff.body.locations[0]).sort(), [...LOCATION_KEYS].sort());

  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  await auth.createShiftRegistration({ shiftId, userId: volunteer.id });

  const detail = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`, volunteer.token);
  assert.equal(detail.status, 200);
  assert.deepEqual(detail.body.myRegistration, { status: 'REGISTERED' });
});

test('archived locations linked to a shift are still visible with isActive false', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await auth.createShift({ locationIds: [locationId] });
  await auth.pool.query('UPDATE locations SET is_active = 0 WHERE location_id = ?', [locationId]);

  const detail = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`, adminToken);
  assert.equal(detail.status, 200);
  assert.equal(detail.body.locations.length, 1);
  assert.equal(detail.body.locations[0].isActive, false);
});

test('filters by status and date', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const openId = await auth.createShift({ locationIds: [locationId], status: 'OPEN', date: '2026-11-01' });
  const closedId = await auth.createShift({ locationIds: [locationId], status: 'CLOSED', date: '2026-11-01' });
  await auth.createShift({ locationIds: [locationId], status: 'OPEN', date: '2026-12-01' });

  const byStatus = await auth.getJson(server.baseUrl, '/api/shifts?status=CLOSED', adminToken);
  assert.deepEqual(byStatus.body.shifts.map((s) => s.id), [closedId]);

  const byDate = await auth.getJson(server.baseUrl, '/api/shifts?date=2026-11-01', adminToken);
  assert.deepEqual(
    byDate.body.shifts.map((s) => s.id).sort(),
    [openId, closedId].sort()
  );
});

test('rejects malformed, empty, unknown and duplicate query parameters', async () => {
  for (const path of [
    '/api/shifts?status=OPENED',
    '/api/shifts?status=',
    '/api/shifts?date=2026-13-01',
    '/api/shifts?date=',
    '/api/shifts?unknown=1',
    '/api/shifts?status=OPEN&status=CLOSED',
  ]) {
    const res = await auth.getJson(server.baseUrl, path, adminToken);
    assert.equal(res.status, 400, path);
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', path);
  }
});

test('malformed and missing shift detail ids are indistinguishable 404s', async () => {
  for (const bad of ['abc', '0', '-1', '1.5', '99999999']) {
    const res = await auth.getJson(server.baseUrl, `/api/shifts/${bad}`, adminToken);
    assert.equal(res.status, 404, bad);
    assert.equal(res.body.error.code, 'NOT_FOUND', bad);
  }
});

test('never exposes audit or internal fields on shifts', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await auth.createShift({ locationIds: [locationId] });

  const res = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`, adminToken);
  for (const key of [
    'createdBy',
    'created_by',
    'createdAt',
    'created_at',
    'updatedAt',
    'updated_at',
    'shift_id',
  ]) {
    assert.ok(!(key in res.body), key);
  }
});
