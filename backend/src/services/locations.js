'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');

const LOCATION_COLUMNS = 'location_id, name, address, is_active';

// Columns required by the shared safe user serializer. Aliased for the JOIN.
const RESPONSIBLE_COLUMNS = `
  u.user_id, u.phone, u.first_name, u.last_name, u.role,
  u.is_active, u.must_change_password
`;

// Safe location shape. Never exposes city, created_by, timestamps or raw rows.
function toSafeLocation(row) {
  return {
    id: row.location_id,
    name: row.name,
    address: row.address,
    isActive: Boolean(row.is_active),
  };
}

// Active locations only, ordered deterministically by name then id.
async function listActiveLocations() {
  const [rows] = await pool.query(
    `SELECT ${LOCATION_COLUMNS} FROM locations
      WHERE is_active = 1
      ORDER BY name ASC, location_id ASC`
  );
  return rows;
}

async function findActiveById(locationId) {
  const [rows] = await pool.query(
    `SELECT ${LOCATION_COLUMNS} FROM locations
      WHERE location_id = ? AND is_active = 1 LIMIT 1`,
    [locationId]
  );
  return rows[0] || null;
}

async function findById(locationId) {
  const [rows] = await pool.query(
    `SELECT ${LOCATION_COLUMNS} FROM locations WHERE location_id = ? LIMIT 1`,
    [locationId]
  );
  return rows[0] || null;
}

// Insert a location as active. On a duplicate-name race this returns
// { created: false } instead of surfacing a raw SQL error.
async function createLocation({ name, address }) {
  try {
    const [result] = await pool.query(
      'INSERT INTO locations (name, address, is_active) VALUES (?, ?, 1)',
      [name, address]
    );
    return { created: true, locationId: result.insertId };
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { created: false, locationId: null };
    }
    throw error;
  }
}

// Partial update of name/address. Only active locations are editable; omitted
// fields are left unchanged. SQL fragments come from a fixed allowlist.
async function updateLocation(locationId, fields) {
  const existing = await findActiveById(locationId);
  if (!existing) return { found: false };

  const sets = [];
  const values = [];
  if (fields.name !== undefined) {
    sets.push('name = ?');
    values.push(fields.name);
  }
  if (fields.address !== undefined) {
    sets.push('address = ?');
    values.push(fields.address);
  }

  values.push(locationId);
  try {
    await pool.query(
      `UPDATE locations SET ${sets.join(', ')} WHERE location_id = ? AND is_active = 1`,
      values
    );
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { found: true, updated: false };
    }
    throw error;
  }

  const location = await findById(locationId);
  return { found: true, updated: true, location };
}

// Archive/reactivate using is_active only. Records are never deleted. Repeating
// the current state is a no-op that returns the existing safe object.
async function setActiveStatus(locationId, isActive) {
  const existing = await findById(locationId);
  if (!existing) return { found: false };

  if (Boolean(existing.is_active) === isActive) {
    return { found: true, location: existing };
  }

  try {
    await pool.query('UPDATE locations SET is_active = ? WHERE location_id = ?', [
      isActive ? 1 : 0,
      locationId,
    ]);
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { found: true, duplicate: true };
    }
    throw error;
  }

  const location = await findById(locationId);
  return { found: true, location };
}

// Only active RESPONSIBLE assignees are ever surfaced, ordered by id. Stale rows
// for inactive or non-RESPONSIBLE users are hidden.
async function listResponsibles(locationId) {
  const [rows] = await pool.query(
    `SELECT ${RESPONSIBLE_COLUMNS}
       FROM responsible_locations rl
       JOIN users u ON u.user_id = rl.user_id
      WHERE rl.location_id = ?
        AND u.role = 'RESPONSIBLE'
        AND u.is_active = 1
      ORDER BY u.user_id ASC`,
    [locationId]
  );
  return rows;
}

// Atomically replace a location's responsible set. The location row is locked
// first so concurrent replacements serialize instead of merging, then the
// referenced users are locked in ascending id order and validated before any
// write. The whole replacement is all-or-nothing.
async function replaceResponsibles(locationId, userIds) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [locationRows] = await connection.query(
      `SELECT ${LOCATION_COLUMNS} FROM locations WHERE location_id = ? FOR UPDATE`,
      [locationId]
    );
    const location = locationRows[0];
    if (!location || !location.is_active) {
      throw new AppError(404, 'NOT_FOUND', 'Location not found.');
    }

    if (userIds.length > 0) {
      const placeholders = userIds.map(() => '?').join(', ');
      const [userRows] = await connection.query(
        `SELECT user_id, role, is_active FROM users
          WHERE user_id IN (${placeholders})
          ORDER BY user_id ASC
          FOR UPDATE`,
        userIds
      );

      const found = new Set(userRows.map((row) => row.user_id));
      const allValid = userRows.every(
        (row) => row.role === 'RESPONSIBLE' && Boolean(row.is_active)
      );
      if (!allValid || found.size !== userIds.length) {
        throw new AppError(
          400,
          'INVALID_RESPONSIBLE',
          'One or more selected users are not active responsible users.'
        );
      }
    }

    await connection.query(
      'DELETE FROM responsible_locations WHERE location_id = ?',
      [locationId]
    );

    if (userIds.length > 0) {
      const values = userIds.map((userId) => [userId, locationId]);
      await connection.query(
        'INSERT INTO responsible_locations (user_id, location_id) VALUES ?',
        [values]
      );
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

  return listResponsibles(locationId);
}

module.exports = {
  LOCATION_COLUMNS,
  toSafeLocation,
  listActiveLocations,
  findActiveById,
  findById,
  createLocation,
  updateLocation,
  setActiveStatus,
  listResponsibles,
  replaceResponsibles,
};
