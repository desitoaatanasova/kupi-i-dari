'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');
const { toSofiaIso } = require('../lib/entry-window');

// Canonical string projection so the DATE value is returned as YYYY-MM-DD
// regardless of driver timezone handling (same convention as `shifts`).
const DISTRIBUTION_COLUMNS = `
  distribution_id, location_id, variant_id,
  DATE_FORMAT(distribution_date, '%Y-%m-%d') AS distribution_date,
  quantity, recipient, note
`;
// Qualified form for queries that JOIN other tables (location_id/variant_id
// would otherwise be ambiguous).
const DISTRIBUTION_COLUMNS_QUALIFIED = `
  d.distribution_id, d.location_id, d.variant_id,
  DATE_FORMAT(d.distribution_date, '%Y-%m-%d') AS distribution_date,
  d.quantity, d.recipient, d.note
`;

// Safe distribution shape. Never exposes distributed_by, distributed_at or raw
// rows. `date` is the Europe/Sofia business date (YYYY-MM-DD); `recipient` and
// `note` are nullable.
function toSafeDistribution(row) {
  return {
    id: row.distribution_id,
    locationId: row.location_id,
    variantId: row.variant_id,
    quantity: Number(row.quantity),
    date: row.distribution_date,
    recipient: row.recipient === undefined ? null : row.recipient,
    note: row.note === undefined ? null : row.note,
  };
}

// List distributions ordered by id (insertion order). Optional filters are bound
// as parameters. When `responsibleUserId` is supplied the query is joined
// against responsible_locations so a RESPONSIBLE only ever sees assigned
// locations. Only static SQL fragments are assembled here; every value is
// parameterised. Date predicates use the application-computed
// `distribution_date` column, so they are timezone-independent.
async function listDistributions({
  locationId,
  variantId,
  productId,
  dateFrom,
  dateTo,
  responsibleUserId,
} = {}) {
  const joins = [];
  const clauses = [];
  const params = [];

  if (responsibleUserId !== undefined) {
    joins.push(
      'JOIN responsible_locations rl ON rl.location_id = d.location_id AND rl.user_id = ?'
    );
    params.push(responsibleUserId);
  }
  if (productId !== undefined) {
    joins.push('JOIN product_variants pv ON pv.variant_id = d.variant_id');
  }
  if (locationId !== undefined) {
    clauses.push('d.location_id = ?');
    params.push(locationId);
  }
  if (variantId !== undefined) {
    clauses.push('d.variant_id = ?');
    params.push(variantId);
  }
  if (productId !== undefined) {
    clauses.push('pv.product_id = ?');
    params.push(productId);
  }
  if (dateFrom !== undefined) {
    clauses.push('d.distribution_date >= ?');
    params.push(dateFrom);
  }
  if (dateTo !== undefined) {
    clauses.push('d.distribution_date <= ?');
    params.push(dateTo);
  }

  const where = clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '';
  const [rows] = await pool.query(
    `SELECT ${DISTRIBUTION_COLUMNS_QUALIFIED}
       FROM distributions d
       ${joins.join(' ')}
       ${where}
      ORDER BY d.distribution_id ASC`,
    params
  );
  return rows;
}

async function findDistributionById(distributionId) {
  const [rows] = await pool.query(
    `SELECT ${DISTRIBUTION_COLUMNS} FROM distributions
      WHERE distribution_id = ? LIMIT 1`,
    [distributionId]
  );
  return rows[0] || null;
}

// Create a distribution. One transaction, lock order: location row -> variant
// row (a sub-order of the project-wide shift -> location -> variant order, so
// it can never deadlock against the staff/volunteer quantity paths). The
// location and parent product must be active; the submitted quantity is stored
// as-is and `distributed_by` is the acting staff user. `now` is injectable for
// deterministic date tests.
async function createDistribution({
  locationId,
  variantId,
  quantity,
  recipient,
  note,
  distributedBy,
  now = new Date(),
}) {
  const distributionDate = toSofiaIso(now).slice(0, 10);
  const connection = await pool.getConnection();
  let insertedId;
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

    const [result] = await connection.query(
      `INSERT INTO distributions
         (location_id, variant_id, distribution_date, quantity, recipient, note, distributed_by)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [locationId, variantId, distributionDate, quantity, recipient, note, distributedBy]
    );
    insertedId = result.insertId;

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

  return findDistributionById(insertedId);
}

// Absolute correction of quantity, recipient and/or note. Existence is checked
// by the caller. Linked entities are deliberately not re-validated: a
// distribution stays correctable even after its location, variant or parent
// product is archived. Location, variant, date and distributor are immutable.
async function updateDistribution(distributionId, fields) {
  const assignments = [];
  const params = [];
  if (fields.quantity !== undefined) {
    assignments.push('quantity = ?');
    params.push(fields.quantity);
  }
  if (fields.recipient !== undefined) {
    assignments.push('recipient = ?');
    params.push(fields.recipient);
  }
  if (fields.note !== undefined) {
    assignments.push('note = ?');
    params.push(fields.note);
  }

  params.push(distributionId);
  await pool.query(
    `UPDATE distributions SET ${assignments.join(', ')} WHERE distribution_id = ?`,
    params
  );
  return findDistributionById(distributionId);
}

module.exports = {
  DISTRIBUTION_COLUMNS,
  DISTRIBUTION_COLUMNS_QUALIFIED,
  toSafeDistribution,
  listDistributions,
  findDistributionById,
  createDistribution,
  updateDistribution,
};
