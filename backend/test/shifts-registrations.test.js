'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const app = require('../src/app');

const REGISTRATION_KEYS = ['id', 'shiftId', 'userId', 'status'];

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

async function makeShift(status = 'OPEN', locationIds = []) {
  return auth.createShift({ locationIds, status });
}

const register = (shiftId, token) =>
  auth.postJson(server.baseUrl, `/api/shifts/${shiftId}/registrations`, {}, token);

const listRegistrations = (shiftId, token) =>
  auth.getJson(server.baseUrl, `/api/shifts/${shiftId}/registrations`, token);

const cancel = (shiftId, registrationId, token) =>
  auth.patchJson(
    server.baseUrl,
    `/api/shifts/${shiftId}/registrations/${registrationId}/cancel`,
    {},
    token
  );

test('registration endpoints require authentication', async () => {
  const shiftId = await makeShift('OPEN');
  const list = await listRegistrations(shiftId, undefined);
  assert.equal(list.status, 401);

  const res = await register(shiftId, undefined);
  assert.equal(res.status, 401);
});

test('volunteers cannot list registrations', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await makeShift('OPEN', [locationId]);
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const res = await listRegistrations(shiftId, volunteer.token);
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'FORBIDDEN');
});

test('admin lists registrations with the exact safe shape', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await makeShift('OPEN', [locationId]);
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const registrationId = await auth.createShiftRegistration({
    shiftId,
    userId: volunteer.id,
  });

  const res = await listRegistrations(shiftId, adminToken);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.registrations.length, 1);
  assert.deepEqual(Object.keys(res.body.registrations[0]).sort(), [...REGISTRATION_KEYS].sort());
  assert.equal(res.body.registrations[0].id, registrationId);
  assert.equal(res.body.registrations[0].shiftId, shiftId);
  assert.equal(res.body.registrations[0].userId, volunteer.id);
  assert.equal(res.body.registrations[0].status, 'REGISTERED');

  for (const key of ['registeredAt', 'registered_at', 'phone', 'firstName', 'lastName']) {
    assert.ok(!(key in res.body.registrations[0]), key);
  }
});

test('a responsible user may list registrations only for an assigned shift', async () => {
  const assignedLocation = await auth.createLocation({ name: uniq('Локация') });
  const otherLocation = await auth.createLocation({ name: uniq('Локация') });
  const assignedShift = await makeShift('OPEN', [assignedLocation]);
  const otherShift = await makeShift('OPEN', [otherLocation]);
  const responsible = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assignedLocation],
  });

  const ok = await listRegistrations(assignedShift, responsible.token);
  assert.equal(ok.status, 200, JSON.stringify(ok.body));

  const denied = await listRegistrations(otherShift, responsible.token);
  assert.equal(denied.status, 403);
  assert.equal(denied.body.error.code, 'FORBIDDEN');
});

test('a responsible user assigned to one of several locations can list all registrations', async () => {
  const assignedLocation = await auth.createLocation({ name: uniq('Локация') });
  const extraLocation = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await makeShift('OPEN', [assignedLocation, extraLocation]);
  const responsible = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assignedLocation],
  });

  const res = await listRegistrations(shiftId, responsible.token);
  assert.equal(res.status, 200);
});

test('volunteers can register themselves for an OPEN shift', async () => {
  const locationId = await auth.createLocation({ name: uniq('Локация') });
  const shiftId = await makeShift('OPEN', [locationId]);
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const res = await register(shiftId, volunteer.token);
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.deepEqual(Object.keys(res.body).sort(), [...REGISTRATION_KEYS].sort());
  assert.equal(res.body.shiftId, shiftId);
  assert.equal(res.body.userId, volunteer.id);
  assert.equal(res.body.status, 'REGISTERED');

  const detail = await auth.getJson(server.baseUrl, `/api/shifts/${shiftId}`, volunteer.token);
  assert.deepEqual(detail.body.myRegistration, { status: 'REGISTERED' });
});

test('staff cannot self-register', async () => {
  const shiftId = await makeShift('OPEN');

  const admin = await register(shiftId, adminToken);
  assert.equal(admin.status, 403);

  const responsible = await auth.createResponsibleToken(server.baseUrl);
  const responsibleRes = await register(shiftId, responsible.token);
  assert.equal(responsibleRes.status, 403);
});

test('a duplicate active registration returns 409 ALREADY_REGISTERED', async () => {
  const shiftId = await makeShift('OPEN');
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const first = await register(shiftId, volunteer.token);
  assert.equal(first.status, 201);

  const second = await register(shiftId, volunteer.token);
  assert.equal(second.status, 409);
  assert.equal(second.body.error.code, 'ALREADY_REGISTERED');
});

test('registration is only possible while the shift is OPEN', async () => {
  for (const status of ['DRAFT', 'CLOSED', 'CANCELLED']) {
    const shiftId = await makeShift(status);
    const volunteer = await auth.createVolunteerToken(server.baseUrl);
    const res = await register(shiftId, volunteer.token);
    assert.equal(res.status, 409, status);
    assert.equal(res.body.error.code, 'SHIFT_NOT_OPEN');
  }
});

test('registering for a missing or malformed shift id fails cleanly', async () => {
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const missing = await register(99999999, volunteer.token);
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');

  const malformed = await register('abc', volunteer.token);
  assert.equal(malformed.status, 400);
  assert.equal(malformed.body.error.code, 'VALIDATION_ERROR');
});

test('cancelling a registration is idempotent and keeps a single row', async () => {
  const shiftId = await makeShift('OPEN');
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const created = await register(shiftId, volunteer.token);
  assert.equal(created.status, 201);

  const first = await cancel(shiftId, created.body.id, volunteer.token);
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.deepEqual(Object.keys(first.body).sort(), [...REGISTRATION_KEYS].sort());
  assert.equal(first.body.status, 'CANCELLED');

  const second = await cancel(shiftId, created.body.id, volunteer.token);
  assert.equal(second.status, 200);
  assert.equal(second.body.status, 'CANCELLED');

  const [rows] = await auth.pool.query(
    'SELECT COUNT(*) AS total FROM shift_registrations WHERE shift_id = ? AND user_id = ?',
    [shiftId, volunteer.id]
  );
  assert.equal(Number(rows[0].total), 1);
});

test('re-registering after cancellation reactivates the row and returns 200', async () => {
  const shiftId = await makeShift('OPEN');
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const created = await register(shiftId, volunteer.token);

  await cancel(shiftId, created.body.id, volunteer.token);
  const again = await register(shiftId, volunteer.token);

  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.id, created.body.id);
  assert.equal(again.body.status, 'REGISTERED');

  const [rows] = await auth.pool.query(
    'SELECT COUNT(*) AS total FROM shift_registrations WHERE shift_id = ? AND user_id = ?',
    [shiftId, volunteer.id]
  );
  assert.equal(Number(rows[0].total), 1);
});

test('a volunteer cannot cancel another volunteer registration and gets 404', async () => {
  const shiftId = await makeShift('OPEN');
  const owner = await auth.createVolunteerToken(server.baseUrl);
  const other = await auth.createVolunteerToken(server.baseUrl);
  const created = await register(shiftId, owner.token);

  const res = await cancel(shiftId, created.body.id, other.token);
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');

  const stillRegistered = await auth.getJson(
    server.baseUrl,
    `/api/shifts/${shiftId}/registrations`,
    adminToken
  );
  assert.equal(stillRegistered.body.registrations[0].status, 'REGISTERED');
});

test('an admin can cancel any registration', async () => {
  const shiftId = await makeShift('OPEN');
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const created = await register(shiftId, volunteer.token);

  const res = await cancel(shiftId, created.body.id, adminToken);
  assert.equal(res.status, 200);
  assert.equal(res.body.status, 'CANCELLED');
});

test('registrations cannot change once the shift is no longer OPEN', async () => {
  const shiftId = await makeShift('OPEN');
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const created = await register(shiftId, volunteer.token);

  await auth.pool.query("UPDATE shifts SET status = 'CLOSED' WHERE shift_id = ?", [shiftId]);

  const cancelled = await cancel(shiftId, created.body.id, volunteer.token);
  assert.equal(cancelled.status, 409);
  assert.equal(cancelled.body.error.code, 'SHIFT_NOT_OPEN');

  const registerAgain = await register(shiftId, (await auth.createVolunteerToken(server.baseUrl)).token);
  assert.equal(registerAgain.status, 409);
  assert.equal(registerAgain.body.error.code, 'SHIFT_NOT_OPEN');
});

test('cancelling a missing registration or one from another shift returns 404', async () => {
  const shiftId = await makeShift('OPEN');
  const otherShiftId = await makeShift('OPEN');
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  const created = await register(shiftId, volunteer.token);

  const missing = await cancel(shiftId, 99999999, volunteer.token);
  assert.equal(missing.status, 404);

  const wrongShift = await cancel(otherShiftId, created.body.id, volunteer.token);
  assert.equal(wrongShift.status, 404);

  const malformed = await cancel(shiftId, 'abc', volunteer.token);
  assert.equal(malformed.status, 400);
  assert.equal(malformed.body.error.code, 'VALIDATION_ERROR');
});
