'use strict';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { ensureMigrated } = require('./helpers/db');
const auth = require('./helpers/auth');
const shiftEntry = require('../src/services/shift-entry');
const app = require('../src/app');

const QUANTITY_KEYS = ['id', 'shiftId', 'locationId', 'variantId', 'quantity'];
const CONTEXT_KEYS = ['shift', 'canSubmit', 'submissionError', 'entryWindow', 'locations', 'quantities'];
const SOFIA_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/;

let server;
let adminToken;
let nameSeq = 0;

before(async () => {
  await ensureMigrated();
  server = await auth.startServer(app);
});

after(async () => {
  await server.close();
  await auth.cleanQuantities();
  await auth.cleanShifts();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  await auth.pool.end();
});

beforeEach(async () => {
  await auth.cleanQuantities();
  await auth.cleanShifts();
  await auth.cleanProducts();
  await auth.cleanLocations();
  await auth.cleanUsers();
  adminToken = (await auth.createAdminToken(server.baseUrl)).token;
});

function uniq(prefix) {
  nameSeq += 1;
  return `${prefix} ${nameSeq}`;
}

// Current calendar date in Europe/Sofia (YYYY-MM-DD).
function todaySofia() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/Sofia',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function yesterdaySofia() {
  const date = new Date();
  date.setDate(date.getDate() - 1);
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/Sofia',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date);
}

async function makeLocation(isActive = true) {
  return auth.createLocation({ name: uniq('Локация'), isActive });
}

async function makeVariant(options = {}) {
  const productId = await auth.createProduct({
    name: uniq('Продукт'),
    isActive: options.productActive !== false,
  });
  return auth.createVariant({
    productId,
    unitLabel: '1 бр',
    isActive: options.isActive !== false,
  });
}

// An OPEN shift covering all of today, so the real clock is always inside the
// entry window [00:00, 23:59 + 30 min].
async function openShiftFor(locationIds) {
  return auth.createShift({
    date: todaySofia(),
    startTime: '00:00:00',
    endTime: '23:59:00',
    status: 'OPEN',
    locationIds,
  });
}

async function volunteerFor(shiftId, status = 'REGISTERED') {
  const volunteer = await auth.createVolunteerToken(server.baseUrl);
  await auth.createShiftRegistration({ shiftId, userId: volunteer.id, status });
  return volunteer;
}

const getEntry = (shiftId, token) =>
  auth.getJson(server.baseUrl, `/api/shifts/${shiftId}/entry`, token);

const putQuantities = (shiftId, body, token) =>
  auth.putJson(server.baseUrl, `/api/shifts/${shiftId}/quantities`, body, token);

// ---------------------------------------------------------------------------
// GET /api/shifts/:shiftId/entry
// ---------------------------------------------------------------------------

test('entry context requires authentication', async () => {
  const locationId = await makeLocation();
  const shiftId = await openShiftFor([locationId]);
  const res = await getEntry(shiftId, undefined);
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'UNAUTHORIZED');
});

test('entry context returns 404 for missing and malformed shift ids', async () => {
  const missing = await getEntry(99999999, adminToken);
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');

  const malformed = await getEntry('abc', adminToken);
  assert.equal(malformed.status, 404);
  assert.equal(malformed.body.error.code, 'NOT_FOUND');
});

test('volunteers cannot discover DRAFT shifts but staff can see the entry context', async () => {
  const locationId = await makeLocation();
  const shiftId = await auth.createShift({
    date: todaySofia(),
    startTime: '00:00:00',
    endTime: '23:59:00',
    status: 'DRAFT',
    locationIds: [locationId],
  });
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const hidden = await getEntry(shiftId, volunteer.token);
  assert.equal(hidden.status, 404);

  const staff = await getEntry(shiftId, adminToken);
  assert.equal(staff.status, 200, JSON.stringify(staff.body));
  assert.equal(staff.body.canSubmit, false);
  assert.equal(staff.body.submissionError, 'ROLE_NOT_VOLUNTEER');
});

test('a registered volunteer gets a submittable OPEN context with the exact shape', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);
  await auth.createCollectedQuantity({ locationId, variantId, quantity: 4, shiftId });

  const res = await getEntry(shiftId, volunteer.token);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(Object.keys(res.body).sort(), [...CONTEXT_KEYS].sort());
  assert.equal(res.body.canSubmit, true);
  assert.equal(res.body.submissionError, null);
  assert.match(res.body.entryWindow.opensAt, SOFIA_ISO);
  assert.match(res.body.entryWindow.closesAt, SOFIA_ISO);
  assert.deepEqual(res.body.locations.map((l) => l.id), [locationId]);
  assert.deepEqual(Object.keys(res.body.locations[0]).sort(), ['address', 'id', 'isActive', 'name']);
  assert.equal(res.body.quantities.length, 1);
  assert.deepEqual(Object.keys(res.body.quantities[0]).sort(), [...QUANTITY_KEYS].sort());
  assert.equal(res.body.quantities[0].shiftId, shiftId);

  assert.deepEqual(Object.keys(res.body.shift).sort(), [
    'date', 'endTime', 'id', 'startTime', 'status', 'title',
  ]);
});

test('the entry context never exposes PII or audit metadata', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);
  await auth.createCollectedQuantity({ locationId, variantId, quantity: 1, shiftId });

  const res = await getEntry(shiftId, volunteer.token);
  const serialized = JSON.stringify(res.body);
  for (const forbidden of [
    'phone',
    'password',
    'token',
    'recordedBy',
    'recorded_by',
    'recordedAt',
    'registered_at',
    'firstName',
    'lastName',
    'shift_id',
    'collected_quantity_id',
  ]) {
    assert.ok(!serialized.includes(forbidden), forbidden);
  }
});

test('a volunteer without an active registration sees REGISTRATION_REQUIRED', async () => {
  const locationId = await makeLocation();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const res = await getEntry(shiftId, volunteer.token);
  assert.equal(res.status, 200);
  assert.equal(res.body.canSubmit, false);
  assert.equal(res.body.submissionError, 'REGISTRATION_REQUIRED');
});

test('a cancelled registration sees REGISTRATION_REQUIRED; reactivation restores submission', async () => {
  const locationId = await makeLocation();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId, 'CANCELLED');

  const before = await getEntry(shiftId, volunteer.token);
  assert.equal(before.body.submissionError, 'REGISTRATION_REQUIRED');

  await auth.pool.query(
    "UPDATE shift_registrations SET status = 'REGISTERED' WHERE shift_id = ? AND user_id = ?",
    [shiftId, volunteer.id]
  );
  const after = await getEntry(shiftId, volunteer.token);
  assert.equal(after.body.canSubmit, true);
});

test('CLOSED and CANCELLED shifts report SHIFT_NOT_OPEN', async () => {
  const locationId = await makeLocation();
  for (const status of ['CLOSED', 'CANCELLED']) {
    const shiftId = await auth.createShift({
      date: todaySofia(),
      startTime: '00:00:00',
      endTime: '23:59:00',
      status,
      locationIds: [locationId],
    });
    const volunteer = await volunteerFor(shiftId);
    const res = await getEntry(shiftId, volunteer.token);
    assert.equal(res.status, 200, status);
    assert.equal(res.body.canSubmit, false, status);
    assert.equal(res.body.submissionError, 'SHIFT_NOT_OPEN', status);
  }
});

test('a shift entirely outside the window reports ENTRY_WINDOW_CLOSED', async () => {
  const locationId = await makeLocation();
  const shiftId = await auth.createShift({
    date: yesterdaySofia(),
    startTime: '09:00:00',
    endTime: '10:00:00',
    status: 'OPEN',
    locationIds: [locationId],
  });
  const volunteer = await volunteerFor(shiftId);

  const res = await getEntry(shiftId, volunteer.token);
  assert.equal(res.body.canSubmit, false);
  assert.equal(res.body.submissionError, 'ENTRY_WINDOW_CLOSED');
});

test('staff receive ROLE_NOT_VOLUNTEER; admin sees every quantity row', async () => {
  const locationA = await makeLocation();
  const locationB = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationA, locationB]);
  await auth.createCollectedQuantity({ locationId: locationA, variantId, quantity: 1, shiftId });
  await auth.createCollectedQuantity({ locationId: locationB, variantId, quantity: 2, shiftId });

  const res = await getEntry(shiftId, adminToken);
  assert.equal(res.status, 200);
  assert.equal(res.body.canSubmit, false);
  assert.equal(res.body.submissionError, 'ROLE_NOT_VOLUNTEER');
  assert.equal(res.body.quantities.length, 2);
});

test('a RESPONSIBLE sees only assigned locations and their quantity rows', async () => {
  const assignedLocation = await makeLocation();
  const otherLocation = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([assignedLocation, otherLocation]);
  await auth.createCollectedQuantity({
    locationId: assignedLocation,
    variantId,
    quantity: 5,
    shiftId,
  });
  await auth.createCollectedQuantity({
    locationId: otherLocation,
    variantId,
    quantity: 6,
    shiftId,
  });
  const responsible = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [assignedLocation],
  });

  const res = await getEntry(shiftId, responsible.token);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.locations.map((l) => l.id), [assignedLocation]);
  assert.equal(res.body.quantities.length, 1);
  assert.equal(res.body.quantities[0].locationId, assignedLocation);
});

test('entry context lists only active locations of the shift', async () => {
  const activeLocation = await makeLocation();
  const archivedLocation = await makeLocation(false);
  const shiftId = await openShiftFor([activeLocation, archivedLocation]);
  const volunteer = await volunteerFor(shiftId);

  const res = await getEntry(shiftId, volunteer.token);
  assert.deepEqual(res.body.locations.map((l) => l.id), [activeLocation]);
});

// ---------------------------------------------------------------------------
// PUT /api/shifts/:shiftId/quantities
// ---------------------------------------------------------------------------

test('quantity submission requires a VOLUNTEER token', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const body = { locationId, quantities: [{ variantId, quantity: 1 }] };

  const anonymous = await putQuantities(shiftId, body, undefined);
  assert.equal(anonymous.status, 401);

  const admin = await putQuantities(shiftId, body, adminToken);
  assert.equal(admin.status, 403);
  assert.equal(admin.body.error.code, 'FORBIDDEN');

  const responsible = await auth.createResponsibleToken(server.baseUrl, {
    locationIds: [locationId],
  });
  const resp = await putQuantities(shiftId, body, responsible.token);
  assert.equal(resp.status, 403);
  assert.equal(resp.body.error.code, 'FORBIDDEN');
});

test('a registered volunteer submits quantities and gets every row for the location', async () => {
  const locationId = await makeLocation();
  const variantA = await makeVariant();
  const variantB = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);

  const res = await putQuantities(
    shiftId,
    {
      locationId,
      quantities: [
        { variantId: variantB, quantity: 3 },
        { variantId: variantA, quantity: 0 },
      ],
    },
    volunteer.token
  );

  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.quantities.length, 2);
  // Ordered by variantId ascending.
  assert.deepEqual(
    res.body.quantities.map((q) => q.variantId),
    [variantA, variantB].sort((a, b) => a - b)
  );
  for (const row of res.body.quantities) {
    assert.deepEqual(Object.keys(row).sort(), [...QUANTITY_KEYS].sort());
    assert.equal(row.shiftId, shiftId);
    assert.equal(row.locationId, locationId);
  }
  const byVariant = new Map(res.body.quantities.map((q) => [q.variantId, q.quantity]));
  assert.equal(byVariant.get(variantA), 0);
  assert.equal(byVariant.get(variantB), 3);

  const [rows] = await auth.pool.query(
    'SELECT recorded_by FROM collected_quantities WHERE shift_id = ? AND location_id = ? AND variant_id = ?',
    [shiftId, locationId, variantA]
  );
  assert.equal(Number(rows[0].recorded_by), volunteer.id);
});

test('submissions are absolute replacements and omitted variants are untouched', async () => {
  const locationId = await makeLocation();
  const variantA = await makeVariant();
  const variantB = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);

  await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId: variantA, quantity: 5 }, { variantId: variantB, quantity: 9 }] },
    volunteer.token
  );
  const second = await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId: variantA, quantity: 2 }] },
    volunteer.token
  );

  const byVariant = new Map(second.body.quantities.map((q) => [q.variantId, q.quantity]));
  assert.equal(byVariant.get(variantA), 2);
  assert.equal(byVariant.get(variantB), 9);

  const [countRows] = await auth.pool.query(
    'SELECT COUNT(*) AS total FROM collected_quantities WHERE shift_id = ? AND location_id = ?',
    [shiftId, locationId]
  );
  assert.equal(Number(countRows[0].total), 2);
});

test('an explicit zero overwrites a previous quantity', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);

  await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId, quantity: 12 }] },
    volunteer.token
  );
  const res = await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId, quantity: 0 }] },
    volunteer.token
  );
  assert.equal(res.status, 200);
  assert.equal(res.body.quantities[0].quantity, 0);
});

test('identical retries are idempotent and keep a single row', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);
  const body = { locationId, quantities: [{ variantId, quantity: 7 }] };

  const first = await putQuantities(shiftId, body, volunteer.token);
  const second = await putQuantities(shiftId, body, volunteer.token);
  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(second.body.quantities[0].id, first.body.quantities[0].id);
  assert.equal(second.body.quantities[0].quantity, 7);

  const [rows] = await auth.pool.query(
    'SELECT COUNT(*) AS total FROM collected_quantities WHERE shift_id = ? AND location_id = ? AND variant_id = ?',
    [shiftId, locationId, variantId]
  );
  assert.equal(Number(rows[0].total), 1);
});

test('the same variant at the same location is separate per shift', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shift1 = await openShiftFor([locationId]);
  const shift2 = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shift1);

  await putQuantities(
    shift1,
    { locationId, quantities: [{ variantId, quantity: 3 }] },
    volunteer.token
  );
  const other = await volunteerFor(shift2);
  await putQuantities(
    shift2,
    { locationId, quantities: [{ variantId, quantity: 8 }] },
    other.token
  );

  const [rows] = await auth.pool.query(
    'SELECT shift_id, quantity FROM collected_quantities WHERE location_id = ? AND variant_id = ? ORDER BY shift_id',
    [locationId, variantId]
  );
  assert.deepEqual(
    rows.map((r) => [Number(r.shift_id), Number(r.quantity)]),
    [
      [shift1, 3],
      [shift2, 8],
    ]
  );
});

test('a volunteer without a registration is rejected with REGISTRATION_REQUIRED', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const res = await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId, quantity: 1 }] },
    volunteer.token
  );
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'REGISTRATION_REQUIRED');
});

test('a cancelled registration cannot submit', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId, 'CANCELLED');

  const res = await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId, quantity: 1 }] },
    volunteer.token
  );
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'REGISTRATION_REQUIRED');
});

test('submission is only possible while the shift is OPEN', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  for (const status of ['CLOSED', 'CANCELLED']) {
    const shiftId = await auth.createShift({
      date: todaySofia(),
      startTime: '00:00:00',
      endTime: '23:59:00',
      status,
      locationIds: [locationId],
    });
    const volunteer = await volunteerFor(shiftId);
    const res = await putQuantities(
      shiftId,
      { locationId, quantities: [{ variantId, quantity: 1 }] },
      volunteer.token
    );
    assert.equal(res.status, 409, status);
    assert.equal(res.body.error.code, 'SHIFT_NOT_OPEN', status);
  }
});

test('a submission outside the window is rejected with ENTRY_WINDOW_CLOSED', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await auth.createShift({
    date: yesterdaySofia(),
    startTime: '09:00:00',
    endTime: '10:00:00',
    status: 'OPEN',
    locationIds: [locationId],
  });
  const volunteer = await volunteerFor(shiftId);

  const res = await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId, quantity: 1 }] },
    volunteer.token
  );
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'ENTRY_WINDOW_CLOSED');
});

test('a location not assigned to the shift is rejected', async () => {
  const shiftLocation = await makeLocation();
  const otherLocation = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([shiftLocation]);
  const volunteer = await volunteerFor(shiftId);

  const res = await putQuantities(
    shiftId,
    { locationId: otherLocation, quantities: [{ variantId, quantity: 1 }] },
    volunteer.token
  );
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'LOCATION_NOT_IN_SHIFT');
});

test('archived locations, variants and parents are rejected with 404', async () => {
  const locationId = await makeLocation();
  const archivedLocation = await makeLocation(false);
  const archivedVariant = await makeVariant({ isActive: false });
  const variantUnderArchivedProduct = await makeVariant({ productActive: false });
  const shiftId = await openShiftFor([locationId, archivedLocation]);
  const volunteer = await volunteerFor(shiftId);

  const cases = [
    { locationId: archivedLocation, variantId: (await makeVariant()) },
    { locationId, variantId: archivedVariant },
    { locationId, variantId: variantUnderArchivedProduct },
    { locationId, variantId: 99999999 },
  ];
  for (const entry of cases) {
    const res = await putQuantities(
      shiftId,
      { locationId: entry.locationId, quantities: [{ variantId: entry.variantId, quantity: 1 }] },
      volunteer.token
    );
    assert.equal(res.status, 404, JSON.stringify(entry));
    assert.equal(res.body.error.code, 'NOT_FOUND', JSON.stringify(entry));
  }
});

test('a missing shift returns 404 and a malformed shift id returns 400', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const body = { locationId, quantities: [{ variantId, quantity: 1 }] };
  const volunteer = await auth.createVolunteerToken(server.baseUrl);

  const missing = await putQuantities(99999999, body, volunteer.token);
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'NOT_FOUND');

  const malformed = await putQuantities('abc', body, volunteer.token);
  assert.equal(malformed.status, 400);
  assert.equal(malformed.body.error.code, 'VALIDATION_ERROR');
});

test('one invalid item rolls the whole batch back with no partial writes', async () => {
  const locationId = await makeLocation();
  const validVariant = await makeVariant();
  const archivedVariant = await makeVariant({ isActive: false });
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);

  const res = await putQuantities(
    shiftId,
    {
      locationId,
      quantities: [
        { variantId: validVariant, quantity: 5 },
        { variantId: archivedVariant, quantity: 5 },
      ],
    },
    volunteer.token
  );
  assert.equal(res.status, 404);

  const [rows] = await auth.pool.query('SELECT COUNT(*) AS total FROM collected_quantities');
  assert.equal(Number(rows[0].total), 0);
});

test('rejects malformed and invalid submission bodies', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);

  const cases = [
    [],
    {},
    { locationId },
    { locationId, quantities: [] },
    { locationId, quantities: 'nope' },
    { locationId, quantities: [{ variantId, quantity: 1 }, { variantId, quantity: 2 }] },
    { locationId, quantities: [{ variantId, quantity: -1 }] },
    { locationId, quantities: [{ variantId, quantity: 1.5 }] },
    { locationId, quantities: [{ variantId, quantity: '2' }] },
    { locationId, quantities: [{ variantId, quantity: 2147483648 }] },
    { locationId, quantities: [{ variantId, quantity: 1, extra: true }] },
    { locationId, quantities: [{ quantity: 1 }] },
    { locationId, quantities: [{ variantId }] },
    { locationId, quantities: [null] },
    { locationId: 'x', quantities: [{ variantId, quantity: 1 }] },
    { locationId: 0, quantities: [{ variantId, quantity: 1 }] },
    { locationId, quantities: [{ variantId, quantity: 1 }], extra: true },
  ];

  for (const body of cases) {
    const res = await putQuantities(shiftId, body, volunteer.token);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'VALIDATION_ERROR', JSON.stringify(body));
  }

  // A `null` body is not valid JSON under express.json()'s strict parser, so it
  // never reaches the route; only the status is guaranteed.
  const nullBody = await putQuantities(shiftId, null, volunteer.token);
  assert.equal(nullBody.status, 400);

  const tooMany = {
    locationId,
    quantities: Array.from({ length: 101 }, (_, index) => ({ variantId: 1, quantity: 0 })),
  };
  const res = await putQuantities(shiftId, tooMany, volunteer.token);
  assert.equal(res.status, 400);
});

test('a DISABLED volunteer account cannot submit or read the context', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);

  await auth.pool.query('UPDATE users SET is_active = 0 WHERE user_id = ?', [volunteer.id]);

  const put = await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId, quantity: 1 }] },
    volunteer.token
  );
  assert.equal(put.status, 403);
  assert.equal(put.body.error.code, 'ACCOUNT_DISABLED');

  const entry = await getEntry(shiftId, volunteer.token);
  assert.equal(entry.status, 403);
  assert.equal(entry.body.error.code, 'ACCOUNT_DISABLED');
});

test('concurrent volunteer submissions settle on a single row', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);
  const values = [1, 2, 3, 4, 5];

  const results = await Promise.all(
    values.map((quantity) =>
      putQuantities(shiftId, { locationId, quantities: [{ variantId, quantity }] }, volunteer.token)
    )
  );
  // The write rate limiter is loose in tests (10000); all requests succeed.
  assert.ok(results.every((r) => r.status === 200), JSON.stringify(results.map((r) => r.status)));

  const [rows] = await auth.pool.query(
    'SELECT quantity FROM collected_quantities WHERE shift_id = ? AND location_id = ? AND variant_id = ?',
    [shiftId, locationId, variantId]
  );
  assert.equal(rows.length, 1);
  assert.ok(values.includes(Number(rows[0].quantity)));
});

test('concurrent volunteer and staff writes cannot deadlock', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);

  const [volunteerRes, staffRes] = await Promise.all([
    putQuantities(
      shiftId,
      { locationId, quantities: [{ variantId, quantity: 4 }] },
      volunteer.token
    ),
    auth.postJson(
      server.baseUrl,
      '/api/quantities',
      { locationId, variantId, quantity: 6, shiftId },
      adminToken
    ),
  ]);

  assert.equal(volunteerRes.status, 200, JSON.stringify(volunteerRes.body));
  assert.ok([200, 201].includes(staffRes.status), JSON.stringify(staffRes.body));

  const [rows] = await auth.pool.query(
    'SELECT quantity FROM collected_quantities WHERE shift_id = ? AND location_id = ? AND variant_id = ?',
    [shiftId, locationId, variantId]
  );
  assert.equal(rows.length, 1);
  assert.ok([4, 6].includes(Number(rows[0].quantity)));
});

test('an entry submission never touches a legacy unlinked row', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await openShiftFor([locationId]);
  const volunteer = await volunteerFor(shiftId);
  const legacyId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 4 });

  await putQuantities(
    shiftId,
    { locationId, quantities: [{ variantId, quantity: 9 }] },
    volunteer.token
  );

  const [legacyRows] = await auth.pool.query(
    'SELECT quantity, shift_id FROM collected_quantities WHERE collected_quantity_id = ?',
    [legacyId]
  );
  assert.equal(legacyRow(legacyRows[0]).quantity, 4);
  assert.equal(legacyRow(legacyRows[0]).shiftId, null);
});

function legacyRow(row) {
  return { quantity: Number(row.quantity), shiftId: row.shift_id };
}

// ---------------------------------------------------------------------------
// Deterministic entry-window boundaries (injected clock)
// ---------------------------------------------------------------------------

test('entry-window boundaries are enforced with an injected clock', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const shiftId = await auth.createShift({
    date: '2026-05-01',
    startTime: '09:00:00',
    endTime: '13:00:00',
    status: 'OPEN',
    locationIds: [locationId],
  });
  const volunteer = await volunteerFor(shiftId);

  const base = {
    shiftId,
    userId: volunteer.id,
    locationId,
    items: [{ variantId, quantity: 1 }],
  };

  const outsideBefore = await shiftEntry
    .submitQuantities({ ...base, now: new Date('2026-05-01T08:59:59') })
    .then(() => null, (error) => error);
  assert.equal(outsideBefore.code, 'ENTRY_WINDOW_CLOSED');

  const atOpen = await shiftEntry.submitQuantities({
    ...base,
    now: new Date('2026-05-01T09:00:00'),
  });
  assert.equal(atOpen.quantities.length, 1);

  const beforeClose = await shiftEntry.submitQuantities({
    ...base,
    now: new Date('2026-05-01T13:29:59'),
  });
  assert.equal(beforeClose.quantities.length, 1);

  const atClose = await shiftEntry.submitQuantities({
    ...base,
    now: new Date('2026-05-01T13:30:00'),
  });
  assert.equal(atClose.quantities.length, 1);

  const outsideAfter = await shiftEntry
    .submitQuantities({ ...base, now: new Date('2026-05-01T13:30:01') })
    .then(() => null, (error) => error);
  assert.equal(outsideAfter.code, 'ENTRY_WINDOW_CLOSED');
});

// ---------------------------------------------------------------------------
// Schema / migration assertions
// ---------------------------------------------------------------------------

test('the shift/location/variant unique index exists and shift_id is nullable', async () => {
  const [indexRows] = await auth.pool.query(
    `SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, SEQ_IN_INDEX
       FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'collected_quantities'
      ORDER BY INDEX_NAME, SEQ_IN_INDEX`
  );
  const index = indexRows.filter((row) => row.INDEX_NAME === 'uq_collected_shift_location_variant');
  assert.deepEqual(
    index.map((row) => row.COLUMN_NAME),
    ['shift_id', 'location_id', 'variant_id']
  );
  assert.ok(index.every((row) => Number(row.NON_UNIQUE) === 0));
  assert.ok(!indexRows.some((row) => row.INDEX_NAME === 'uq_collected_location_variant'));

  const [columnRows] = await auth.pool.query(
    `SELECT IS_NULLABLE FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'collected_quantities'
        AND COLUMN_NAME = 'shift_id'`
  );
  assert.equal(columnRows[0].IS_NULLABLE, 'YES');
});

test('unlinked legacy rows are readable and never backfilled', async () => {
  const locationId = await makeLocation();
  const variantId = await makeVariant();
  const legacyId = await auth.createCollectedQuantity({ locationId, variantId, quantity: 3 });

  const res = await auth.getJson(server.baseUrl, `/api/quantities/${legacyId}`, adminToken);
  assert.equal(res.status, 200);
  assert.equal(res.body.shiftId, null);
  assert.equal(res.body.quantity, 3);

  const [rows] = await auth.pool.query(
    'SELECT shift_id FROM collected_quantities WHERE collected_quantity_id = ?',
    [legacyId]
  );
  assert.equal(rows[0].shift_id, null);
});
