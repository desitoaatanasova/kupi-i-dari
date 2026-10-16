'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');

// Canonical string projections so DATE/TIME values are returned predictably
// regardless of driver timezone handling. `shift_date` -> YYYY-MM-DD,
// `start_time`/`end_time` -> HH:MM:SS.
const SHIFT_COLUMNS = `
  shift_id, title,
  DATE_FORMAT(shift_date, '%Y-%m-%d') AS shift_date,
  TIME_FORMAT(start_time, '%H:%i:%s') AS start_time,
  TIME_FORMAT(end_time, '%H:%i:%s') AS end_time,
  status
`;

const REGISTRATION_COLUMNS = 'registration_id, shift_id, user_id, status';

// Status lifecycle. Repeating the current status is idempotent; every other
// pair is rejected. There is no reopen and no hard delete.
const ALLOWED_TRANSITIONS = {
  DRAFT: ['OPEN', 'CANCELLED'],
  OPEN: ['CLOSED', 'CANCELLED'],
  CLOSED: [],
  CANCELLED: [],
};

const EDITABLE_STATUSES = ['DRAFT', 'OPEN'];

// Safe shift shape. Never exposes created_by, timestamps or raw rows.
function toSafeShift(row) {
  return {
    id: row.shift_id,
    title: row.title === undefined ? null : row.title,
    date: row.shift_date,
    startTime: row.start_time,
    endTime: row.end_time,
    status: row.status,
  };
}

// Safe registration shape. Never exposes registered_at, phone numbers or the
// registrant's profile.
function toSafeRegistration(row) {
  return {
    id: row.registration_id,
    shiftId: row.shift_id,
    userId: row.user_id,
    status: row.status,
  };
}

// List shifts ordered deterministically. Volunteers never see DRAFT shifts;
// staff may. Optional `status` and `date` filters are always parameterised.
async function listShifts({ status, date, includeDraft = true } = {}) {
  const clauses = [];
  const params = [];
  if (!includeDraft) clauses.push("status <> 'DRAFT'");
  if (status !== undefined) {
    clauses.push('status = ?');
    params.push(status);
  }
  if (date !== undefined) {
    clauses.push('shift_date = ?');
    params.push(date);
  }
  const where = clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '';
  const [rows] = await pool.query(
    `SELECT ${SHIFT_COLUMNS} FROM shifts ${where}
      ORDER BY shift_date ASC, start_time ASC, shift_id ASC`,
    params
  );
  return rows;
}

async function findShiftById(shiftId) {
  const [rows] = await pool.query(
    `SELECT ${SHIFT_COLUMNS} FROM shifts WHERE shift_id = ? LIMIT 1`,
    [shiftId]
  );
  return rows[0] || null;
}

// Locations linked to a shift. Archived locations are still returned (their
// isActive flag is false) because they are part of the shift's history.
async function listShiftLocations(shiftId) {
  const [rows] = await pool.query(
    `SELECT l.location_id, l.name, l.address, l.is_active
       FROM shift_locations sl
       JOIN locations l ON l.location_id = sl.location_id
      WHERE sl.shift_id = ?
      ORDER BY l.name ASC, l.location_id ASC`,
    [shiftId]
  );
  return rows;
}

// Validate a set of location ids inside the caller's transaction. Locks the
// referenced rows in ascending id order first so concurrent assignment changes
// serialize and the active-state check is not racy. Throws INVALID_LOCATION on
// any missing or inactive id, which rolls the surrounding transaction back.
async function assertActiveLocations(connection, locationIds) {
  const placeholders = locationIds.map(() => '?').join(', ');
  const [rows] = await connection.query(
    `SELECT location_id, is_active FROM locations
      WHERE location_id IN (${placeholders})
      ORDER BY location_id ASC
      FOR UPDATE`,
    locationIds
  );
  const found = new Set(rows.map((row) => row.location_id));
  const allActive = rows.every((row) => Boolean(row.is_active));
  if (!allActive || found.size !== locationIds.length) {
    throw new AppError(
      400,
      'INVALID_LOCATION',
      'One or more selected locations are missing or inactive.'
    );
  }
}

// Create a shift (always DRAFT) together with its location set, atomically.
// Locations are locked and validated before any write, so an invalid selection
// leaves no partial shift.
async function createShift({ title, date, startTime, endTime, locationIds, createdBy }) {
  if (endTime <= startTime) {
    throw new AppError(400, 'VALIDATION_ERROR', 'endTime must be later than startTime.');
  }

  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    await assertActiveLocations(connection, locationIds);

    const [result] = await connection.query(
      `INSERT INTO shifts (title, shift_date, start_time, end_time, status, created_by)
       VALUES (?, ?, ?, ?, 'DRAFT', ?)`,
      [title, date, startTime, endTime, createdBy]
    );
    const shiftId = result.insertId;

    const values = locationIds.map((locationId) => [shiftId, locationId]);
    await connection.query(
      'INSERT INTO shift_locations (shift_id, location_id) VALUES ?',
      [values]
    );

    await connection.commit();
    return { shiftId };
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
}

// Partial update of title/date/times. Only DRAFT/OPEN shifts are editable, and
// the row is locked first so concurrent updates and status changes serialize.
// The combined (existing + supplied) start/end is validated before writing.
async function updateShift(shiftId, fields) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [rows] = await connection.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts WHERE shift_id = ? FOR UPDATE`,
      [shiftId]
    );
    const existing = rows[0];
    if (!existing) {
      await connection.commit();
      return { found: false };
    }

    if (!EDITABLE_STATUSES.includes(existing.status)) {
      await connection.commit();
      return { found: true, editable: false, shift: toSafeShift(existing) };
    }

    const startTime = fields.startTime !== undefined ? fields.startTime : existing.start_time;
    const endTime = fields.endTime !== undefined ? fields.endTime : existing.end_time;
    if (endTime <= startTime) {
      throw new AppError(400, 'VALIDATION_ERROR', 'endTime must be later than startTime.');
    }

    const sets = [];
    const values = [];
    if (fields.title !== undefined) {
      sets.push('title = ?');
      values.push(fields.title);
    }
    if (fields.date !== undefined) {
      sets.push('shift_date = ?');
      values.push(fields.date);
    }
    if (fields.startTime !== undefined) {
      sets.push('start_time = ?');
      values.push(fields.startTime);
    }
    if (fields.endTime !== undefined) {
      sets.push('end_time = ?');
      values.push(fields.endTime);
    }

    values.push(shiftId);
    await connection.query(
      `UPDATE shifts SET ${sets.join(', ')} WHERE shift_id = ?`,
      values
    );
    await connection.commit();

    const shift = await findShiftById(shiftId);
    return { found: true, editable: true, shift: toSafeShift(shift) };
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
}

// Transition a shift's status. The row is locked first; repeating the current
// status is an idempotent no-op.
async function setStatus(shiftId, status) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [rows] = await connection.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts WHERE shift_id = ? FOR UPDATE`,
      [shiftId]
    );
    const existing = rows[0];
    if (!existing) {
      await connection.commit();
      return { found: false };
    }

    if (existing.status === status) {
      await connection.commit();
      return { found: true, valid: true, shift: toSafeShift(existing) };
    }

    const allowed = ALLOWED_TRANSITIONS[existing.status] || [];
    if (!allowed.includes(status)) {
      await connection.commit();
      return { found: true, valid: false, shift: toSafeShift(existing) };
    }

    await connection.query('UPDATE shifts SET status = ? WHERE shift_id = ?', [
      status,
      shiftId,
    ]);
    await connection.commit();

    const shift = await findShiftById(shiftId);
    return { found: true, valid: true, shift: toSafeShift(shift) };
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
}

// Atomically replace a shift's location set. The shift row is locked first
// (existence + editable status), then the locations are locked/validated in
// ascending id order before any write. All-or-nothing.
async function replaceLocations(shiftId, locationIds) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [shiftRows] = await connection.query(
      'SELECT shift_id, status FROM shifts WHERE shift_id = ? FOR UPDATE',
      [shiftId]
    );
    const shift = shiftRows[0];
    if (!shift) {
      throw new AppError(404, 'NOT_FOUND', 'Shift not found.');
    }
    if (!EDITABLE_STATUSES.includes(shift.status)) {
      throw new AppError(
        409,
        'SHIFT_NOT_EDITABLE',
        'Locations can only be changed while the shift is DRAFT or OPEN.'
      );
    }

    await assertActiveLocations(connection, locationIds);

    await connection.query('DELETE FROM shift_locations WHERE shift_id = ?', [shiftId]);
    const values = locationIds.map((locationId) => [shiftId, locationId]);
    await connection.query(
      'INSERT INTO shift_locations (shift_id, location_id) VALUES ?',
      [values]
    );

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

  return listShiftLocations(shiftId);
}

// Every registration for a shift, ordered by id.
async function listRegistrations(shiftId) {
  const [rows] = await pool.query(
    `SELECT ${REGISTRATION_COLUMNS} FROM shift_registrations
      WHERE shift_id = ?
      ORDER BY registration_id ASC`,
    [shiftId]
  );
  return rows;
}

async function findRegistrationForUser(shiftId, userId) {
  const [rows] = await pool.query(
    `SELECT ${REGISTRATION_COLUMNS} FROM shift_registrations
      WHERE shift_id = ? AND user_id = ? LIMIT 1`,
    [shiftId, userId]
  );
  return rows[0] || null;
}

// Whether a RESPONSIBLE user is assigned to at least one location of a shift.
// Used to scope registration-list access.
async function isResponsibleForShift(shiftId, userId) {
  const [rows] = await pool.query(
    `SELECT 1 FROM shift_locations sl
       JOIN responsible_locations rl
         ON rl.location_id = sl.location_id AND rl.user_id = ?
      WHERE sl.shift_id = ? LIMIT 1`,
    [userId, shiftId]
  );
  return rows.length > 0;
}

// Volunteer self-registration. The shift row is locked first, so concurrent
// registrations for the same shift serialize. Registration is only allowed
// while the shift is OPEN; a previously CANCELLED row is reactivated (200),
// while an active duplicate is a conflict (409).
async function registerSelf(shiftId, userId) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [shiftRows] = await connection.query(
      'SELECT shift_id, status FROM shifts WHERE shift_id = ? FOR UPDATE',
      [shiftId]
    );
    const shift = shiftRows[0];
    if (!shift) {
      await connection.commit();
      return { found: false };
    }
    if (shift.status !== 'OPEN') {
      await connection.commit();
      return { found: true, open: false };
    }

    const [existingRows] = await connection.query(
      `SELECT ${REGISTRATION_COLUMNS} FROM shift_registrations
        WHERE shift_id = ? AND user_id = ? FOR UPDATE`,
      [shiftId, userId]
    );
    const existing = existingRows[0];

    if (existing && existing.status === 'REGISTERED') {
      await connection.commit();
      return { found: true, open: true, duplicate: true };
    }

    let registrationId;
    if (existing) {
      await connection.query(
        "UPDATE shift_registrations SET status = 'REGISTERED', registered_at = NOW() WHERE registration_id = ?",
        [existing.registration_id]
      );
      registrationId = existing.registration_id;
    } else {
      const [result] = await connection.query(
        `INSERT INTO shift_registrations (shift_id, user_id, status)
         VALUES (?, ?, 'REGISTERED')`,
        [shiftId, userId]
      );
      registrationId = result.insertId;
    }

    await connection.commit();

    const [rows] = await pool.query(
      `SELECT ${REGISTRATION_COLUMNS} FROM shift_registrations WHERE registration_id = ?`,
      [registrationId]
    );
    return { found: true, open: true, created: !existing, registration: rows[0] };
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
}

// Cancel a registration. Only OPEN shifts accept changes. A volunteer may only
// touch their own registration; a non-owner is reported as not found so the
// registration's existence is never revealed. Cancelling twice is idempotent.
async function cancelRegistration({ shiftId, registrationId, userId, isAdmin }) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [shiftRows] = await connection.query(
      'SELECT shift_id, status FROM shifts WHERE shift_id = ? FOR UPDATE',
      [shiftId]
    );
    const shift = shiftRows[0];
    if (!shift) {
      await connection.commit();
      return { found: false };
    }
    if (shift.status !== 'OPEN') {
      await connection.commit();
      return { found: true, open: false };
    }

    const [regRows] = await connection.query(
      `SELECT ${REGISTRATION_COLUMNS} FROM shift_registrations
        WHERE registration_id = ? AND shift_id = ? FOR UPDATE`,
      [registrationId, shiftId]
    );
    const existing = regRows[0];
    if (!existing) {
      await connection.commit();
      return { found: false };
    }
    if (!isAdmin && existing.user_id !== userId) {
      await connection.commit();
      return { found: false };
    }

    if (existing.status !== 'CANCELLED') {
      await connection.query(
        "UPDATE shift_registrations SET status = 'CANCELLED' WHERE registration_id = ?",
        [registrationId]
      );
    }
    await connection.commit();

    const [rows] = await pool.query(
      `SELECT ${REGISTRATION_COLUMNS} FROM shift_registrations WHERE registration_id = ?`,
      [registrationId]
    );
    return { found: true, open: true, registration: rows[0] };
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
}

module.exports = {
  SHIFT_COLUMNS,
  toSafeShift,
  toSafeRegistration,
  listShifts,
  findShiftById,
  listShiftLocations,
  createShift,
  updateShift,
  setStatus,
  replaceLocations,
  listRegistrations,
  findRegistrationForUser,
  isResponsibleForShift,
  registerSelf,
  cancelRegistration,
};
