'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');

const USER_COLUMNS = `
  user_id, phone, password_hash, first_name, last_name, role,
  is_active, token_version, must_change_password, last_login_at
`;

async function findByPhone(phone) {
  const [rows] = await pool.query(
    `SELECT ${USER_COLUMNS} FROM users WHERE phone = ? LIMIT 1`,
    [phone]
  );
  return rows[0] || null;
}

async function findById(userId) {
  const [rows] = await pool.query(
    `SELECT ${USER_COLUMNS} FROM users WHERE user_id = ? LIMIT 1`,
    [userId]
  );
  return rows[0] || null;
}

// Create a VOLUNTEER with no password hash. On a duplicate-phone race this
// returns { created: false } instead of surfacing a raw SQL error.
async function createVolunteer({ firstName, lastName, phone }) {
  try {
    const [result] = await pool.query(
      `INSERT INTO users (phone, password_hash, first_name, last_name, role, is_active)
       VALUES (?, NULL, ?, ?, 'VOLUNTEER', 1)`,
      [phone, firstName, lastName]
    );
    return { created: true, userId: result.insertId };
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { created: false, userId: null };
    }
    throw error;
  }
}

async function touchLastLogin(userId) {
  await pool.query('UPDATE users SET last_login_at = NOW() WHERE user_id = ?', [
    userId,
  ]);
}

// Atomically bump the token version so every previously issued token is stale.
async function incrementTokenVersion(userId) {
  const [result] = await pool.query(
    'UPDATE users SET token_version = token_version + 1 WHERE user_id = ?',
    [userId]
  );
  return result.affectedRows;
}

// Replace the password hash, clear the forced-change flag and revoke every
// previously issued token in a single statement. Returns the refreshed row.
async function setPasswordAndClearMustChange(userId, passwordHash) {
  const [result] = await pool.query(
    `UPDATE users
        SET password_hash = ?, must_change_password = 0,
            token_version = token_version + 1
      WHERE user_id = ?`,
    [passwordHash, userId]
  );
  if (result.affectedRows === 0) return null;
  return findById(userId);
}

// Public/safe projection. Never exposes password_hash, token_version or audit fields.
function toSafeProfile(row) {
  return {
    id: row.user_id,
    phone: row.phone,
    firstName: row.first_name,
    lastName: row.last_name,
    role: row.role,
    isActive: Boolean(row.is_active),
    mustChangePassword: Boolean(row.must_change_password),
  };
}

// Build a parameterized WHERE clause shared by listing and counting so the two
// always agree. Only static SQL fragments are interpolated; user values are bound.
function buildUserFilters({ role, isActive }) {
  const clauses = [];
  const params = [];
  if (role !== undefined) {
    clauses.push('role = ?');
    params.push(role);
  }
  if (isActive !== undefined) {
    clauses.push('is_active = ?');
    params.push(isActive ? 1 : 0);
  }
  return {
    where: clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '',
    params,
  };
}

// List users matching the optional filters. Ordered by the unique id so equal
// values never yield an arbitrary order, with a stable LIMIT/OFFSET window.
async function listUsers({ role, isActive, limit, offset }) {
  const { where, params } = buildUserFilters({ role, isActive });
  const [rows] = await pool.query(
    `SELECT ${USER_COLUMNS} FROM users ${where} ORDER BY user_id ASC LIMIT ? OFFSET ?`,
    [...params, limit, offset]
  );
  return rows;
}

async function countUsers({ role, isActive }) {
  const { where, params } = buildUserFilters({ role, isActive });
  const [rows] = await pool.query(
    `SELECT COUNT(*) AS total FROM users ${where}`,
    params
  );
  return Number(rows[0].total);
}

// Create a staff account (RESPONSIBLE/ADMIN) with a pre-hashed password. Records
// the acting administrator and forces a password change on first login.
async function createStaff({ phone, firstName, lastName, role, passwordHash, createdBy }) {
  try {
    const [result] = await pool.query(
      `INSERT INTO users
         (phone, password_hash, first_name, last_name, role, is_active,
          must_change_password, created_by)
       VALUES (?, ?, ?, ?, ?, 1, 1, ?)`,
      [phone, passwordHash, firstName, lastName, role, createdBy]
    );
    return { created: true, userId: result.insertId };
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { created: false, userId: null };
    }
    throw error;
  }
}

// Update only the permitted editable profile fields. Omitted fields are left
// untouched; role/password/security columns are never addressable here.
async function updateProfile(userId, fields) {
  const existing = await findById(userId);
  if (!existing) return { found: false };

  const sets = [];
  const values = [];
  if (fields.firstName !== undefined) {
    sets.push('first_name = ?');
    values.push(fields.firstName);
  }
  if (fields.lastName !== undefined) {
    sets.push('last_name = ?');
    values.push(fields.lastName);
  }
  if (fields.phone !== undefined) {
    sets.push('phone = ?');
    values.push(fields.phone);
  }

  values.push(userId);
  try {
    await pool.query(`UPDATE users SET ${sets.join(', ')} WHERE user_id = ?`, values);
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { found: true, updated: false };
    }
    throw error;
  }

  const user = await findById(userId);
  return { found: true, updated: true, user };
}

// Activate or deactivate an account inside a transaction that protects the last
// active administrator. All ADMIN rows are locked in id order first so concurrent
// status changes serialize instead of racing on a stale count.
async function setActiveStatus(userId, isActive, actingAdminId) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();

    const [adminRows] = await connection.query(
      "SELECT user_id, is_active FROM users WHERE role = 'ADMIN' ORDER BY user_id FOR UPDATE"
    );

    const [targetRows] = await connection.query(
      `SELECT ${USER_COLUMNS} FROM users WHERE user_id = ? FOR UPDATE`,
      [userId]
    );
    const target = targetRows[0];
    if (!target) {
      throw new AppError(404, 'NOT_FOUND', 'User not found.');
    }

    const currentlyActive = Boolean(target.is_active);
    if (currentlyActive === isActive) {
      await connection.commit();
      return toSafeProfile(target);
    }

    if (!isActive) {
      if (target.user_id === actingAdminId) {
        throw new AppError(
          409,
          'SELF_DEACTIVATION',
          'You cannot deactivate your own account.'
        );
      }
      if (target.role === 'ADMIN' && currentlyActive) {
        const activeAdmins = adminRows.filter((row) => Boolean(row.is_active)).length;
        if (activeAdmins <= 1) {
          throw new AppError(
            409,
            'LAST_ADMIN',
            'The last active administrator cannot be deactivated.'
          );
        }
      }
    }

    await connection.query('UPDATE users SET is_active = ? WHERE user_id = ?', [
      isActive ? 1 : 0,
      userId,
    ]);
    await connection.commit();
    return toSafeProfile({ ...target, is_active: isActive ? 1 : 0 });
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
  findByPhone,
  findById,
  createVolunteer,
  touchLastLogin,
  incrementTokenVersion,
  setPasswordAndClearMustChange,
  toSafeProfile,
  listUsers,
  countUsers,
  createStaff,
  updateProfile,
  setActiveStatus,
};
