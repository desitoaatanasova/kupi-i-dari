'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateBody } = require('../lib/validate');
const { signToken, expiresInSeconds } = require('../lib/jwt');
const { verifyPassword, verifyWithDummy, hashPassword } = require('../lib/password');
const users = require('../services/users');
const { authenticate } = require('../middleware/authenticate');
const {
  loginLimiter,
  volunteerLimiter,
  registerLimiter,
  volunteerLoginLimiter,
} = require('../middleware/auth-rate-limit');

const router = express.Router();

const STAFF_ROLES = ['RESPONSIBLE', 'ADMIN'];
const PUBLIC_REGISTRATION_ROLES = ['VOLUNTEER'];

function invalidCredentials() {
  return new AppError(401, 'INVALID_CREDENTIALS', 'Invalid phone number or password.');
}

function normalizeName(value) {
  return String(value || '')
    .trim()
    .replace(/\s+/g, ' ')
    .toLowerCase();
}

function namesMatch(stored, supplied) {
  return normalizeName(stored) === normalizeName(supplied);
}

function tokenResponse(user) {
  return {
    token: signToken(user),
    tokenType: 'Bearer',
    expiresIn: expiresInSeconds(),
    user: users.toSafeProfile(user),
  };
}

// Staff login: phone + password for RESPONSIBLE / ADMIN accounts.
router.post('/login', loginLimiter, async (req, res, next) => {
  try {
    const { phone, password } = validateBody(req.body || {}, {
      phone: { type: 'phone' },
      password: { type: 'string', min: 1, max: 200, trim: false },
    });

    const user = await users.findByPhone(phone);

    let valid = false;
    if (user && user.password_hash && STAFF_ROLES.includes(user.role)) {
      valid = await verifyPassword(password, user.password_hash);
    } else {
      // Unknown phone or a non-staff account: burn comparable time, then fail
      // with the same generic response (no account enumeration).
      await verifyWithDummy(password);
    }

    if (!valid || !user) throw invalidCredentials();
    if (!user.is_active) {
      throw new AppError(403, 'ACCOUNT_DISABLED', 'This account is disabled.');
    }

    await users.touchLastLogin(user.user_id);
    res.status(200).json(tokenResponse(user));
  } catch (error) {
    next(error);
  }
});

// Public volunteer registration. Only VOLUNTEER may be self-registered; staff
// accounts remain admin-provisioned with passwords.
router.post('/register', registerLimiter, async (req, res, next) => {
  try {
    const { firstName, lastName, phone, role } = validateBody(req.body || {}, {
      firstName: { type: 'string', min: 1, max: 60, collapse: true },
      lastName: { type: 'string', min: 1, max: 60, collapse: true },
      phone: { type: 'phone' },
      role: { type: 'enum', values: PUBLIC_REGISTRATION_ROLES },
    });

    const result = await users.createVolunteer({ firstName, lastName, phone });
    if (!result.created) {
      throw new AppError(
        409,
        'PHONE_TAKEN',
        'A user with this phone number already exists.'
      );
    }

    const user = await users.findById(result.userId);
    if (!user || user.role !== 'VOLUNTEER') {
      throw new AppError(500, 'INTERNAL_ERROR', 'Registration failed.');
    }

    await users.touchLastLogin(user.user_id);
    res.status(201).json(tokenResponse(user));
  } catch (error) {
    next(error);
  }
});

// Strict volunteer login: existing active VOLUNTEER only. Never creates an
// account, and returns the same generic error for unknown phones, name
// mismatches and staff accounts so the response does not enumerate users.
router.post('/volunteer/login', volunteerLoginLimiter, async (req, res, next) => {
  try {
    const { firstName, lastName, phone } = validateBody(req.body || {}, {
      firstName: { type: 'string', min: 1, max: 60, collapse: true },
      lastName: { type: 'string', min: 1, max: 60, collapse: true },
      phone: { type: 'phone' },
    });

    const user = await users.findByPhone(phone);
    if (
      !user ||
      user.role !== 'VOLUNTEER' ||
      !namesMatch(user.first_name, firstName) ||
      !namesMatch(user.last_name, lastName)
    ) {
      throw invalidCredentials();
    }

    if (!user.is_active) {
      throw new AppError(403, 'ACCOUNT_DISABLED', 'This account is disabled.');
    }

    await users.touchLastLogin(user.user_id);
    res.status(200).json(tokenResponse(user));
  } catch (error) {
    next(error);
  }
});

// Legacy volunteer identification: first name + last name + phone (no password).
// Kept unchanged for backward compatibility; the Flutter client uses the strict
// /volunteer/login endpoint instead.
router.post('/volunteer', volunteerLimiter, async (req, res, next) => {
  try {
    const { firstName, lastName, phone } = validateBody(req.body || {}, {
      firstName: { type: 'string', min: 1, max: 60, collapse: true },
      lastName: { type: 'string', min: 1, max: 60, collapse: true },
      phone: { type: 'phone' },
    });

    let user = await users.findByPhone(phone);
    if (!user) {
      await users.createVolunteer({ firstName, lastName, phone });
      // Re-read so a concurrent first-time request converges on one row.
      user = await users.findByPhone(phone);
    }

    if (
      !user ||
      user.role !== 'VOLUNTEER' ||
      !namesMatch(user.first_name, firstName) ||
      !namesMatch(user.last_name, lastName)
    ) {
      throw new AppError(401, 'INVALID_CREDENTIALS', 'Invalid credentials.');
    }

    if (!user.is_active) {
      throw new AppError(403, 'ACCOUNT_DISABLED', 'This account is disabled.');
    }

    await users.touchLastLogin(user.user_id);
    res.status(200).json(tokenResponse(user));
  } catch (error) {
    next(error);
  }
});

// Current safe profile for the authenticated user.
router.get('/me', authenticate, (req, res) => {
  res.status(200).json(req.user);
});

// Change password for an authenticated account. Clears the forced-change flag
// and revokes all previously issued tokens; returns a fresh token.
router.post('/password/change', authenticate, loginLimiter, async (req, res, next) => {
  try {
    const { currentPassword, newPassword } = validateBody(req.body || {}, {
      currentPassword: { type: 'string', min: 1, max: 200, trim: false },
      newPassword: { type: 'string', min: 8, max: 200, trim: false },
    });

    const user = await users.findById(req.user.id);

    // Only staff accounts with a password hash may change their own password;
    // password-less volunteers and unknown users fail identically.
    if (!user || !user.password_hash) throw invalidCredentials();

    if (!user.is_active) {
      throw new AppError(403, 'ACCOUNT_DISABLED', 'This account is disabled.');
    }

    if (newPassword === currentPassword) {
      throw new AppError(
        400,
        'VALIDATION_ERROR',
        'New password must be different from the current password.'
      );
    }

    const valid = await verifyPassword(currentPassword, user.password_hash);
    if (!valid) throw invalidCredentials();

    const passwordHash = await hashPassword(newPassword);
    const updated = await users.setPasswordAndClearMustChange(user.user_id, passwordHash);
    if (!updated) throw invalidCredentials();

    res.status(200).json(tokenResponse(updated));
  } catch (error) {
    next(error);
  }
});

// Logout: revoke all tokens issued with the current token version.
router.post('/logout', authenticate, async (req, res, next) => {
  try {
    await users.incrementTokenVersion(req.user.id);
    res.status(204).end();
  } catch (error) {
    next(error);
  }
});

module.exports = router;
