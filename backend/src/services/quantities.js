'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');

const QUANTITY_COLUMNS = 'collected_quantity_id, location_id, variant_id, quantity';
// Qualified form for queries that JOIN other tables (location_id/variant_id
// would otherwise be ambiguous).
const QUANTITY_COLUMNS_QUALIFIED =
  'cq.collected_quantity_id, cq.location_id, cq.variant_id, cq.quantity';

// Safe quantity shape. Never exposes recorded_by, recorded_at, updated_at,
// shift_id or raw rows. `quantity` is INT, so it is normalised to a number.
function toSafeQuantity(row) {
  return {
    id: row.collected_quantity_id,
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
async function listQuantities({ locationId, variantId, productId, responsibleUserId } = {}) {
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
      WHERE location_id = ? AND variant_id = ? LIMIT 1`,
    [locationId, variantId]
  );
  return rows[0] || null;
}

// Atomic upsert keyed by (location_id, variant_id): the submitted quantity is an
// absolute replacement, never an increment. The location row is locked first so
// concurrent writes to the same location serialize; the fresh INSERT and its
// ER_DUP_ENTRY fallback make the created/updated decision reliable without
// depending on affectedRows semantics. Variant and parent product must be active.
async function upsertQuantity({ locationId, variantId, quantity, recordedBy }) {
  const connection = await pool.getConnection();
  let created = false;
  try {
    await connection.beginTransaction();

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

    try {
      await connection.query(
        `INSERT INTO collected_quantities
           (shift_id, location_id, variant_id, quantity, recorded_by)
         VALUES (NULL, ?, ?, ?, ?)`,
        [locationId, variantId, quantity, recordedBy]
      );
      created = true;
    } catch (error) {
      if (!error || error.code !== 'ER_DUP_ENTRY') throw error;
      await connection.query(
        `UPDATE collected_quantities
            SET quantity = ?, recorded_by = ?
          WHERE location_id = ? AND variant_id = ?`,
        [quantity, recordedBy, locationId, variantId]
      );
      created = false;
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

  const row = await findQuantityForPair(locationId, variantId);
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
  toSafeQuantity,
  isResponsibleForLocation,
  listQuantities,
  findQuantityById,
  findQuantityForPair,
  upsertQuantity,
  setQuantityValue,
};
