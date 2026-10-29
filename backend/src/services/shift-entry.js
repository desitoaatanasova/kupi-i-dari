'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');
const { getEntryWindow, isWithinEntryWindow, toSofiaIso } = require('../lib/entry-window');
const shifts = require('./shifts');
const locations = require('./locations');
const quantities = require('./quantities');

// Active locations linked to a shift. When `responsibleUserId` is supplied
// only that user's assigned locations are returned (RESPONSIBLE scope).
async function listEntryLocations(shiftId, responsibleUserId) {
  const joins = [];
  const params = [];
  if (responsibleUserId !== undefined) {
    joins.push(
      'JOIN responsible_locations rl ON rl.location_id = l.location_id AND rl.user_id = ?'
    );
    params.push(responsibleUserId);
  }
  params.push(shiftId);
  const [rows] = await pool.query(
    `SELECT l.location_id, l.name, l.address, l.is_active
       FROM shift_locations sl
       JOIN locations l ON l.location_id = sl.location_id
       ${joins.join(' ')}
      WHERE sl.shift_id = ? AND l.is_active = 1
      ORDER BY l.name ASC, l.location_id ASC`,
    params
  );
  return rows;
}

// Quantity rows belonging to a shift, ordered deterministically. When
// `responsibleUserId` is supplied only rows at that user's assigned locations
// are returned (RESPONSIBLE scope).
async function listShiftQuantities(shiftId, responsibleUserId) {
  const joins = [];
  const params = [];
  if (responsibleUserId !== undefined) {
    joins.push(
      'JOIN responsible_locations rl ON rl.location_id = cq.location_id AND rl.user_id = ?'
    );
    params.push(responsibleUserId);
  }
  params.push(shiftId);
  const [rows] = await pool.query(
    `SELECT ${quantities.QUANTITY_COLUMNS_QUALIFIED}
       FROM collected_quantities cq
       ${joins.join(' ')}
      WHERE cq.shift_id = ?
      ORDER BY cq.location_id ASC, cq.variant_id ASC, cq.collected_quantity_id ASC`,
    params
  );
  return rows;
}

// Deterministic reason for a caller being unable to submit. Ordered so the
// response never depends on evaluation incidental order: role, then shift
// lifecycle, then the caller's own registration, then the wall clock. Reveals
// nothing about other volunteers.
function computeSubmissionError({ role, shiftRow, registration, now }) {
  if (role !== 'VOLUNTEER') return 'ROLE_NOT_VOLUNTEER';
  if (shiftRow.status !== 'OPEN') return 'SHIFT_NOT_OPEN';
  if (!registration || registration.status !== 'REGISTERED') return 'REGISTRATION_REQUIRED';
  if (!isWithinEntryWindow(shiftRow, now)) return 'ENTRY_WINDOW_CLOSED';
  return null;
}

// Entry context for GET /api/shifts/:shiftId/entry. Missing or (for
// volunteers) DRAFT shifts are reported as not found so they stay
// indistinguishable, matching the shift detail route.
async function getEntryContext({ shiftId, user, now = new Date() }) {
  const row = await shifts.findShiftById(shiftId);
  if (!row) return { found: false };
  if (user.role === 'VOLUNTEER' && row.status === 'DRAFT') return { found: false };

  const registration = await shifts.findRegistrationForUser(shiftId, user.id);
  const submissionError = computeSubmissionError({
    role: user.role,
    shiftRow: row,
    registration,
    now,
  });
  const responsibleUserId = user.role === 'RESPONSIBLE' ? user.id : undefined;
  const [locationRows, quantityRows] = await Promise.all([
    listEntryLocations(shiftId, responsibleUserId),
    listShiftQuantities(shiftId, responsibleUserId),
  ]);
  const window = getEntryWindow(row);

  return {
    found: true,
    context: {
      shift: shifts.toSafeShift(row),
      canSubmit: submissionError === null,
      submissionError,
      entryWindow: {
        opensAt: toSofiaIso(window.opensAt),
        closesAt: toSofiaIso(window.closesAt),
      },
      locations: locationRows.map(locations.toSafeLocation),
      quantities: quantityRows.map(quantities.toSafeQuantity),
    },
  };
}

// Volunteer submission for PUT /api/shifts/:shiftId/quantities.
//
// One transaction, global lock order: shift row -> caller's registration ->
// target location -> variants (ascending id). All eligibility depends on
// mutable state and is re-checked under those locks; any failure rolls the
// whole batch back (no partial writes). Values are absolute replacements
// keyed by (shift_id, location_id, variant_id); omitted variants are
// untouched. `now` is injectable for deterministic window tests.
async function submitQuantities({ shiftId, userId, locationId, items, now = new Date() }) {
  const orderedItems = items.slice().sort((a, b) => a.variantId - b.variantId);
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [shiftRows] = await connection.query(
      `SELECT shift_id, status,
              DATE_FORMAT(shift_date, '%Y-%m-%d') AS shift_date,
              TIME_FORMAT(start_time, '%H:%i:%s') AS start_time,
              TIME_FORMAT(end_time, '%H:%i:%s') AS end_time
         FROM shifts WHERE shift_id = ? FOR UPDATE`,
      [shiftId]
    );
    const shiftRow = shiftRows[0];
    if (!shiftRow) {
      throw new AppError(404, 'NOT_FOUND', 'Shift not found.');
    }
    if (shiftRow.status !== 'OPEN') {
      throw new AppError(409, 'SHIFT_NOT_OPEN', 'Shift is not open for quantity entry.');
    }
    if (!isWithinEntryWindow(shiftRow, now)) {
      throw new AppError(
        409,
        'ENTRY_WINDOW_CLOSED',
        'Quantity entry for this shift is no longer open.'
      );
    }

    const [registrationRows] = await connection.query(
      `SELECT registration_id, status FROM shift_registrations
        WHERE shift_id = ? AND user_id = ? FOR UPDATE`,
      [shiftId, userId]
    );
    const registration = registrationRows[0];
    if (!registration || registration.status !== 'REGISTERED') {
      throw new AppError(
        403,
        'REGISTRATION_REQUIRED',
        'An active registration for this shift is required.'
      );
    }

    const [locationRows] = await connection.query(
      'SELECT location_id FROM locations WHERE location_id = ? AND is_active = 1 FOR UPDATE',
      [locationId]
    );
    if (!locationRows[0]) {
      throw new AppError(404, 'NOT_FOUND', 'Location not found.');
    }

    const [membershipRows] = await connection.query(
      'SELECT 1 FROM shift_locations WHERE shift_id = ? AND location_id = ? LIMIT 1',
      [shiftId, locationId]
    );
    if (!membershipRows[0]) {
      throw new AppError(
        403,
        'LOCATION_NOT_IN_SHIFT',
        'This location is not part of the shift.'
      );
    }

    const variantIds = orderedItems.map((item) => item.variantId);
    const placeholders = variantIds.map(() => '?').join(', ');
    const [variantRows] = await connection.query(
      `SELECT variant_id, product_id, is_active FROM product_variants
        WHERE variant_id IN (${placeholders})
        ORDER BY variant_id ASC
        FOR UPDATE`,
      variantIds
    );
    // Every submitted id must exist, be active, and have an active parent
    // product; any failure rejects the whole batch.
    if (variantRows.length !== variantIds.length) {
      throw new AppError(404, 'NOT_FOUND', 'Variant not found.');
    }
    if (variantRows.some((row) => !row.is_active)) {
      throw new AppError(404, 'NOT_FOUND', 'Variant not found.');
    }
    const productIds = [...new Set(variantRows.map((row) => row.product_id))];
    const productPlaceholders = productIds.map(() => '?').join(', ');
    const [productRows] = await connection.query(
      `SELECT product_id FROM products
        WHERE product_id IN (${productPlaceholders}) AND is_active = 1`,
      productIds
    );
    const activeProducts = new Set(productRows.map((row) => row.product_id));
    if (variantRows.some((row) => !activeProducts.has(row.product_id))) {
      throw new AppError(404, 'NOT_FOUND', 'Variant not found.');
    }

    for (const item of orderedItems) {
      try {
        await connection.query(
          `INSERT INTO collected_quantities
             (shift_id, location_id, variant_id, quantity, recorded_by)
           VALUES (?, ?, ?, ?, ?)`,
          [shiftId, locationId, item.variantId, item.quantity, userId]
        );
      } catch (error) {
        if (!error || error.code !== 'ER_DUP_ENTRY') throw error;
        await connection.query(
          `UPDATE collected_quantities
              SET quantity = ?, recorded_by = ?
            WHERE shift_id = ? AND location_id = ? AND variant_id = ?`,
          [item.quantity, userId, shiftId, locationId, item.variantId]
        );
      }
    }

    await connection.commit();
  } catch (error) {
    try {
      await connection.rollback();
    } catch (rollbackError) {
      // Ignore rollback failures; surface the original error.
    }
    throw error;
  } finally {
    connection.release();
  }

  const [rows] = await pool.query(
    `SELECT ${quantities.QUANTITY_COLUMNS}
       FROM collected_quantities
      WHERE shift_id = ? AND location_id = ?
      ORDER BY variant_id ASC, collected_quantity_id ASC`,
    [shiftId, locationId]
  );
  return { quantities: rows };
}

module.exports = {
  getEntryContext,
  submitQuantities,
  computeSubmissionError,
  listEntryLocations,
  listShiftQuantities,
};
