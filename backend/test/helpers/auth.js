'use strict';

require('./env');

const bcrypt = require('bcryptjs');
const { pool } = require('../../src/db');

const TEST_PASSWORD = 'TestPass123!';
const hashCache = new Map();

async function hashFor(password) {
  if (!hashCache.has(password)) {
    hashCache.set(password, await bcrypt.hash(password, 12));
  }
  return hashCache.get(password);
}

// Remove every user row. Safe on the dedicated test database.
async function cleanUsers() {
  await pool.query('DELETE FROM users');
}

// Remove every quantity record. Safe on the dedicated test database.
async function cleanQuantities() {
  await pool.query('DELETE FROM collected_quantities');
}

// Remove every location. Quantity records, distributions and assignments are
// cleared first so the delete order is explicit rather than relying on
// ON DELETE RESTRICT/CASCADE. Safe on the test database.
async function cleanLocations() {
  await pool.query('DELETE FROM distributions');
  await pool.query('DELETE FROM collected_quantities');
  await pool.query('DELETE FROM responsible_locations');
  await pool.query('DELETE FROM locations');
}

// Remove every product and variant. Quantity records, distributions and
// variants are cleared first so the delete order is explicit rather than
// relying on ON DELETE RESTRICT/CASCADE. Safe on the test database.
async function cleanProducts() {
  await pool.query('DELETE FROM distributions');
  await pool.query('DELETE FROM collected_quantities');
  await pool.query('DELETE FROM product_variants');
  await pool.query('DELETE FROM products');
}

// Remove every distribution record. Safe on the dedicated test database.
async function cleanDistributions() {
  await pool.query('DELETE FROM distributions');
}

// Remove every shift, its location links and its registrations. The links and
// registrations are cleared first so the order is explicit. Safe on the test
// database.
async function cleanShifts() {
  await pool.query('DELETE FROM shift_registrations');
  await pool.query('DELETE FROM shift_locations');
  await pool.query('DELETE FROM shifts');
}

async function createProduct(options) {
  const { name, category = null, isActive = true } = options;
  const [result] = await pool.query(
    'INSERT INTO products (name, category, is_active) VALUES (?, ?, ?)',
    [name, category, isActive ? 1 : 0]
  );
  return result.insertId;
}

async function createVariant(options) {
  const { productId, unitLabel, unitValue = null, isActive = true } = options;
  const [result] = await pool.query(
    'INSERT INTO product_variants (product_id, unit_label, unit_value, is_active) VALUES (?, ?, ?, ?)',
    [productId, unitLabel, unitValue, isActive ? 1 : 0]
  );
  return result.insertId;
}

async function createLocation(options) {
  const {
    name,
    address = 'ул. Тестова 1',
    isActive = true,
  } = options;
  const [result] = await pool.query(
    'INSERT INTO locations (name, address, is_active) VALUES (?, ?, ?)',
    [name, address, isActive ? 1 : 0]
  );
  return result.insertId;
}

// Insert a collected quantity directly (bypassing the API), used to seed read
// tests. `shiftId` defaults to NULL (legacy unlinked Phase 6 row).
async function createCollectedQuantity(options) {
  const { locationId, variantId, quantity = 0, recordedBy = null, shiftId = null } = options;
  const [result] = await pool.query(
    `INSERT INTO collected_quantities
       (shift_id, location_id, variant_id, quantity, recorded_by)
     VALUES (?, ?, ?, ?, ?)`,
    [shiftId, locationId, variantId, quantity, recordedBy]
  );
  return result.insertId;
}

// Assign a user as responsible for a location.
async function assignResponsible(userId, locationId) {
  const [result] = await pool.query(
    'INSERT INTO responsible_locations (user_id, location_id) VALUES (?, ?)',
    [userId, locationId]
  );
  return result.insertId;
}

// Insert a distribution directly (bypassing the API), used to seed read tests.
// `distributionDate` defaults to a fixed Sofia business date.
async function createDistribution(options) {
  const {
    locationId,
    variantId,
    quantity = 1,
    distributionDate = '2026-11-01',
    recipient = null,
    note = null,
    distributedBy = null,
  } = options;
  const [result] = await pool.query(
    `INSERT INTO distributions
       (location_id, variant_id, distribution_date, quantity, recipient, note, distributed_by)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [locationId, variantId, distributionDate, quantity, recipient, note, distributedBy]
  );
  return result.insertId;
}

// Insert a shift directly (bypassing the API), optionally linking locations.
// Returns the new shift id.
async function createShift(options = {}) {
  const {
    title = null,
    date = '2026-11-01',
    startTime = '09:00:00',
    endTime = '13:00:00',
    status = 'DRAFT',
    createdBy = null,
    locationIds = [],
  } = options;
  const [result] = await pool.query(
    `INSERT INTO shifts (title, shift_date, start_time, end_time, status, created_by)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [title, date, startTime, endTime, status, createdBy]
  );
  const shiftId = result.insertId;
  for (const locationId of locationIds) {
    await pool.query(
      'INSERT INTO shift_locations (shift_id, location_id) VALUES (?, ?)',
      [shiftId, locationId]
    );
  }
  return shiftId;
}

// Link a location to a shift directly.
async function linkShiftLocation(shiftId, locationId) {
  const [result] = await pool.query(
    'INSERT INTO shift_locations (shift_id, location_id) VALUES (?, ?)',
    [shiftId, locationId]
  );
  return result.insertId;
}

// Insert a shift registration directly (bypassing the API).
async function createShiftRegistration(options) {
  const { shiftId, userId, status = 'REGISTERED' } = options;
  const [result] = await pool.query(
    'INSERT INTO shift_registrations (shift_id, user_id, status) VALUES (?, ?, ?)',
    [shiftId, userId, status]
  );
  return result.insertId;
}

async function createUser(options) {
  const {
    phone,
    firstName = 'Тест',
    lastName = 'Потребител',
    role = 'VOLUNTEER',
    password = null,
    isActive = true,
  } = options;
  const hash = password ? await hashFor(password) : null;
  const [result] = await pool.query(
    `INSERT INTO users (phone, password_hash, first_name, last_name, role, is_active)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [phone, hash, firstName, lastName, role, isActive ? 1 : 0]
  );
  return result.insertId;
}

function startServer(app) {
  return new Promise((resolve) => {
    const server = app.listen(0);
    server.once('listening', () => {
      const { port } = server.address();
      resolve({
        baseUrl: `http://127.0.0.1:${port}`,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

async function parseBody(response) {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch (error) {
    return text;
  }
}

async function request(baseUrl, method, path, { body, token } = {}) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, body: await parseBody(response), headers: response.headers };
}

const postJson = (baseUrl, path, body, token) =>
  request(baseUrl, 'POST', path, { body, token });
const getJson = (baseUrl, path, token) => request(baseUrl, 'GET', path, { token });
const patchJson = (baseUrl, path, body, token) =>
  request(baseUrl, 'PATCH', path, { body, token });
const putJson = (baseUrl, path, body, token) =>
  request(baseUrl, 'PUT', path, { body, token });

let adminCounter = 0;

// Create an ADMIN account and return a ready-to-use bearer token. Each call uses
// a distinct default phone so multiple admins can coexist within one test.
async function createAdminToken(baseUrl, options = {}) {
  adminCounter += 1;
  const phone = options.phone || `+359887${String(adminCounter).padStart(6, '0')}`;
  const password = options.password || TEST_PASSWORD;
  const id = await createUser({
    phone,
    firstName: options.firstName || 'Админ',
    lastName: options.lastName || 'Тестов',
    role: 'ADMIN',
    password,
  });
  const res = await postJson(baseUrl, '/api/auth/login', { phone, password });
  return { id, token: res.body.token, phone };
}

let volunteerCounter = 0;

// Identify (or create) a VOLUNTEER and return a ready-to-use bearer token. Each
// call uses a distinct default phone so multiple volunteers can coexist.
async function createVolunteerToken(baseUrl, options = {}) {
  volunteerCounter += 1;
  const phone = options.phone || `+359886${String(volunteerCounter).padStart(6, '0')}`;
  const firstName = options.firstName || 'Доброволец';
  const lastName = options.lastName || 'Тестов';
  const res = await postJson(baseUrl, '/api/auth/volunteer', {
    firstName,
    lastName,
    phone,
  });
  return { id: res.body.user.id, token: res.body.token, phone, firstName, lastName };
}

let responsibleCounter = 0;

// Create a RESPONSIBLE account (optionally assigning locations) and return a
// ready-to-use bearer token.
async function createResponsibleToken(baseUrl, options = {}) {
  responsibleCounter += 1;
  const phone = options.phone || `+359885${String(responsibleCounter).padStart(6, '0')}`;
  const password = options.password || TEST_PASSWORD;
  const id = await createUser({
    phone,
    firstName: options.firstName || 'Отговорник',
    lastName: options.lastName || 'Тестов',
    role: 'RESPONSIBLE',
    password,
  });
  for (const locationId of options.locationIds || []) {
    await assignResponsible(id, locationId);
  }
  const res = await postJson(baseUrl, '/api/auth/login', { phone, password });
  return { id, token: res.body.token, phone };
}


module.exports = {
  TEST_PASSWORD,
  pool,
  cleanUsers,
  cleanLocations,
  cleanProducts,
  cleanQuantities,
  cleanShifts,
  cleanDistributions,
  createLocation,
  createProduct,
  createVariant,
  createCollectedQuantity,
  createDistribution,
  assignResponsible,
  createShift,
  linkShiftLocation,
  createShiftRegistration,
  createUser,
  hashFor,
  startServer,
  request,
  postJson,
  getJson,
  patchJson,
  putJson,
  createAdminToken,
  createVolunteerToken,
  createResponsibleToken,
};
