'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');

const QUANTITY_COLUMNS =
  'collected_quantity_id, shift_id, location_id, variant_id, quantity';
// Qualified form for queries that JOIN other tables (location_id/variant_id
// would otherwise be ambiguous).
const QUANTITY_COLUMNS_QUALIFIED =
  'cq.collected_quantity_id, cq.shift_id, cq.location_id, cq.variant_id, cq.quantity';

// Safe quantity shape. Never exposes recorded_by, recorded_at, updated_at or
// raw rows. `shiftId` is exposed (number or null for legacy unlinked rows) so
// staff lists distinguish per-shift records; `quantity` is INT and normalised
// to a number.
function toSafeQuantity(row) {
  return {
    id: row.collected_quantity_id,
    shiftId: row.shift_id === null || row.shift_id === undefined ? null : row.shift_id,
    locationId: row.location_id,
    variantId: row.variant_id,
    quantity: Number(row.quantity),
  };
}

// Whether a user is assigned to a location through responsible_locations.
// Used to scope RESPONSIBLE access; ADMIN is unrestricted and does not call it.
async function isResponsibleForLocation(userId, locationId) {
  const [rows] = await pool.query(
    `SELECT 1 FROM responsible_locations
      WHERE user_id = ? AND location_id = ? LIMIT 1`,
    [userId, locationId]
  );
  return rows.length > 0;
}

// List quantity records ordered by id. Optional filters are bound as parameters.
// When `responsibleUserId` is supplied the query is joined against
// responsible_locations so a RESPONSIBLE only ever sees assigned locations.
// Only static SQL fragments are assembled here; every value is parameterised.
async function listQuantities({
  locationId,
  variantId,
  productId,
  shiftId,
  responsibleUserId,
} = {}) {
  const joins = [];
  const clauses = [];
  const params = [];

  if (responsibleUserId !== undefined) {
    joins.push(
      'JOIN responsible_locations rl ON rl.location_id = cq.location_id AND rl.user_id = ?'
    );
    params.push(responsibleUserId);
  }
  if (productId !== undefined) {
    joins.push('JOIN product_variants pv ON pv.variant_id = cq.variant_id');
  }
  if (locationId !== undefined) {
    clauses.push('cq.location_id = ?');
    params.push(locationId);
  }
  if (variantId !== undefined) {
    clauses.push('cq.variant_id = ?');
    params.push(variantId);
  }
  if (productId !== undefined) {
    clauses.push('pv.product_id = ?');
    params.push(productId);
  }
  if (shiftId !== undefined) {
    clauses.push('cq.shift_id = ?');
    params.push(shiftId);
  }

  const where = clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '';
  const [rows] = await pool.query(
    `SELECT ${QUANTITY_COLUMNS_QUALIFIED}
       FROM collected_quantities cq
       ${joins.join(' ')}
       ${where}
      ORDER BY cq.collected_quantity_id ASC`,
    params
  );
  return rows;
}

async function findQuantityById(quantityId) {
  const [rows] = await pool.query(
    `SELECT ${QUANTITY_COLUMNS} FROM collected_quantities
      WHERE collected_quantity_id = ? LIMIT 1`,
    [quantityId]
  );
  return rows[0] || null;
}

async function findQuantityForPair(locationId, variantId) {
  const [rows] = await pool.query(
    `SELECT ${QUANTITY_COLUMNS} FROM collected_quantities
      WHERE shift_id IS NULL AND location_id = ? AND variant_id = ? LIMIT 1`,
    [locationId, variantId]
  );
  return rows[0] || null;
}

async function findQuantityForShiftTriple(shiftId, locationId, variantId) {
  const [rows] = await pool.query(
    `SELECT ${QUANTITY_COLUMNS} FROM collected_quantities
      WHERE shift_id = ? AND location_id = ? AND variant_id = ? LIMIT 1`,
    [shiftId, locationId, variantId]
  );
  return rows[0] || null;
}

// Atomic upsert. Without `shiftId` the row is unlinked (`shift_id = NULL`,
// legacy Phase 6 model) and keyed by (location_id, variant_id); with `shiftId`
// it is shift-linked and keyed by (shift_id, location_id, variant_id). The
// submitted quantity is an absolute replacement, never an increment.
//
// Lock order (global project convention — never invert):
//   shift-linked:   shift row -> location row -> variant row
//   unlinked:       location row -> variant row   (no shift involved)
// The location row is locked before any read/write so concurrent unlinked
// upserts serialize; that application-level lock is what preserves the
// one-unlinked-row-per-(location, variant) invariant, because MySQL's
// composite unique index does not reject duplicate rows whose `shift_id` is
// NULL — so the unlinked path SELECTs the existing row (FOR UPDATE) and then
// chooses INSERT or UPDATE. Shift-linked writes are serialized by the shift
// row lock (which the volunteer entry path also acquires first), with the
// triple unique index plus an ER_DUP_ENTRY fallback as the backstop. Variant
// and parent product must be active; for shift-linked writes the shift must
// exist (any status — staff management is not lifecycle-gated).
async function upsertQuantity({ locationId, variantId, quantity, recordedBy, shiftId }) {
  const connection = await pool.getConnection();
  let created = false;
  const linked = shiftId !== undefined && shiftId !== null;
  try {
    await connection.beginTransaction();

    if (linked) {
      const [shiftRows] = await connection.query(
        'SELECT shift_id FROM shifts WHERE shift_id = ? FOR UPDATE',
        [shiftId]
      );
      if (!shiftRows[0]) {
        throw new AppError(404, 'NOT_FOUND', 'Shift not found.');
      }
    }

    const [locationRows] = await connection.query(
      'SELECT location_id FROM locations WHERE location_id = ? AND is_active = 1 FOR UPDATE',
      [locationId]
    );
    if (!locationRows[0]) {
      throw new AppError(404, 'NOT_FOUND', 'Location not found.');
    }

    const [variantRows] = await connection.query(
      'SELECT variant_id, product_id, is_active FROM product_variants WHERE variant_id = ? FOR UPDATE',
      [variantId]
    );
    const variant = variantRows[0];
    if (!variant || !variant.is_active) {
      throw new AppError(404, 'NOT_FOUND', 'Variant not found.');
    }

    const [productRows] = await connection.query(
      'SELECT product_id FROM products WHERE product_id = ? AND is_active = 1 LIMIT 1',
      [variant.product_id]
    );
    if (!productRows[0]) {
      throw new AppError(404, 'NOT_FOUND', 'Variant not found.');
    }

    if (linked) {
      try {
        await connection.query(
          `INSERT INTO collected_quantities
             (shift_id, location_id, variant_id, quantity, recorded_by)
           VALUES (?, ?, ?, ?, ?)`,
          [shiftId, locationId, variantId, quantity, recordedBy]
        );
        created = true;
      } catch (error) {
        if (!error || error.code !== 'ER_DUP_ENTRY') throw error;
        await connection.query(
          `UPDATE collected_quantities
              SET quantity = ?, recorded_by = ?
            WHERE shift_id = ? AND location_id = ? AND variant_id = ?`,
          [quantity, recordedBy, shiftId, locationId, variantId]
        );
        created = false;
      }
    } else {
      // The composite unique index cannot enforce one row per (location,
      // variant) for NULL `shift_id` rows, so decide explicitly under the
      // location-row lock acquired above.
      const [existingRows] = await connection.query(
        `SELECT collected_quantity_id FROM collected_quantities
          WHERE shift_id IS NULL AND location_id = ? AND variant_id = ?
          LIMIT 1 FOR UPDATE`,
        [locationId, variantId]
      );
      if (existingRows[0]) {
        await connection.query(
          `UPDATE collected_quantities
              SET quantity = ?, recorded_by = ?
            WHERE collected_quantity_id = ?`,
          [quantity, recordedBy, existingRows[0].collected_quantity_id]
        );
        created = false;
      } else {
        await connection.query(
          `INSERT INTO collected_quantities
             (shift_id, location_id, variant_id, quantity, recorded_by)
           VALUES (NULL, ?, ?, ?, ?)`,
          [locationId, variantId, quantity, recordedBy]
        );
        created = true;
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

  const row = linked
    ? await findQuantityForShiftTriple(shiftId, locationId, variantId)
    : await findQuantityForPair(locationId, variantId);
  return { created, quantity: row };
}

// Absolute replacement of an existing record's quantity. Existence is checked by
// the caller, so no affectedRows interpretation is needed. Linked entities are
// deliberately not re-validated: a recorded count stays correctable even after
// its location, variant or product is archived.
async function setQuantityValue(quantityId, quantity, recordedBy) {
  await pool.query(
    `UPDATE collected_quantities
        SET quantity = ?, recorded_by = ?
      WHERE collected_quantity_id = ?`,
    [quantity, recordedBy, quantityId]
  );
  return findQuantityById(quantityId);
}

module.exports = {
  QUANTITY_COLUMNS,
  QUANTITY_COLUMNS_QUALIFIED,
  toSafeQuantity,
  isResponsibleForLocation,
  listQuantities,
  findQuantityById,
  findQuantityForPair,
  findQuantityForShiftTriple,
  upsertQuantity,
  setQuantityValue,
};
