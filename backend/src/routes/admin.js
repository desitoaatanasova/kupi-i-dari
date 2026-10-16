'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateBody, validateQuery } = require('../lib/validate');
const { hashPassword } = require('../lib/password');
const users = require('../services/users');
const { authenticate, requireRole } = require('../middleware/authenticate');
const { adminWriteLimiter } = require('../middleware/auth-rate-limit');

const router = express.Router();

// Every admin route requires a valid token for an active ADMIN account.
router.use(authenticate, requireRole('ADMIN'));

// Roles an administrator may provision here. Volunteers self-identify elsewhere.
const CREATABLE_ROLES = ['RESPONSIBLE', 'ADMIN'];
const ALL_ROLES = ['VOLUNTEER', 'RESPONSIBLE', 'ADMIN'];

const DEFAULT_PAGE = 1;
const DEFAULT_PAGE_SIZE = 20;
const MAX_PAGE_SIZE = 100;

function parseUserId(raw) {
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new AppError(400, 'VALIDATION_ERROR', 'userId must be a positive integer.');
  }
  const id = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError(400, 'VALIDATION_ERROR', 'userId must be a positive integer.');
  }
  return id;
}

const PROFILE_FIELDS = {
  firstName: { type: 'string', min: 1, max: 60, collapse: true, required: false },
  lastName: { type: 'string', min: 1, max: 60, collapse: true, required: false },
  phone: { type: 'phone', required: false },
};

// GET /api/admin/users — paginated, filtered staff/volunteer listing.
router.get('/users', async (req, res, next) => {
  try {
    const query = validateQuery(req.query, {
      role: { type: 'enum', values: ALL_ROLES, required: false },
      isActive: { type: 'boolean', required: false },
      page: { type: 'int', min: 1, required: false },
      pageSize: { type: 'int', min: 1, max: MAX_PAGE_SIZE, required: false },
    });

    const page = query.page === undefined ? DEFAULT_PAGE : query.page;
    const pageSize = query.pageSize === undefined ? DEFAULT_PAGE_SIZE : query.pageSize;
    const filters = { role: query.role, isActive: query.isActive };

    const total = await users.countUsers(filters);
    const rows = await users.listUsers({
      ...filters,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    });

    res.status(200).json({
      users: rows.map(users.toSafeProfile),
      pagination: {
        page,
        pageSize,
        total,
        totalPages: total === 0 ? 0 : Math.ceil(total / pageSize),
      },
    });
  } catch (error) {
    next(error);
  }
});

// POST /api/admin/users — provision a RESPONSIBLE/ADMIN account.
router.post('/users', adminWriteLimiter, async (req, res, next) => {
  try {
    const body = validateBody(req.body || {}, {
      firstName: { type: 'string', min: 1, max: 60, collapse: true },
      lastName: { type: 'string', min: 1, max: 60, collapse: true },
      phone: { type: 'phone' },
      role: { type: 'enum', values: CREATABLE_ROLES },
      password: { type: 'string', min: 8, max: 200, trim: false },
    });

    const passwordHash = await hashPassword(body.password);
    const result = await users.createStaff({
      phone: body.phone,
      firstName: body.firstName,
      lastName: body.lastName,
      role: body.role,
      passwordHash,
      createdBy: req.user.id,
    });

    if (!result.created) {
      throw new AppError(409, 'PHONE_TAKEN', 'A user with this phone number already exists.');
    }

    const created = await users.findById(result.userId);
    res.status(201).json(users.toSafeProfile(created));
  } catch (error) {
    next(error);
  }
});

// GET /api/admin/users/:userId — single user as a safe profile.
router.get('/users/:userId', async (req, res, next) => {
  try {
    const userId = parseUserId(req.params.userId);
    const user = await users.findById(userId);
    if (!user) throw new AppError(404, 'NOT_FOUND', 'User not found.');
    res.status(200).json(users.toSafeProfile(user));
  } catch (error) {
    next(error);
  }
});

// PATCH /api/admin/users/:userId — update permitted profile fields only.
router.patch('/users/:userId', adminWriteLimiter, async (req, res, next) => {
  try {
    const userId = parseUserId(req.params.userId);
    const body = validateBody(req.body || {}, PROFILE_FIELDS);

    const fields = {};
    if (body.firstName !== undefined) fields.firstName = body.firstName;
    if (body.lastName !== undefined) fields.lastName = body.lastName;
    if (body.phone !== undefined) fields.phone = body.phone;

    if (Object.keys(fields).length === 0) {
      throw new AppError(
        400,
        'VALIDATION_ERROR',
        'Provide at least one of firstName, lastName or phone.'
      );
    }

    const result = await users.updateProfile(userId, fields);
    if (!result.found) throw new AppError(404, 'NOT_FOUND', 'User not found.');
    if (!result.updated) {
      throw new AppError(409, 'PHONE_TAKEN', 'A user with this phone number already exists.');
    }

    res.status(200).json(users.toSafeProfile(result.user));
  } catch (error) {
    next(error);
  }
});

// PATCH /api/admin/users/:userId/status — activate/deactivate with last-admin safety.
router.patch('/users/:userId/status', adminWriteLimiter, async (req, res, next) => {
  try {
    const userId = parseUserId(req.params.userId);
    const body = validateBody(req.body || {}, {
      isActive: { type: 'boolean' },
    });

    const profile = await users.setActiveStatus(userId, body.isActive, req.user.id);
    res.status(200).json(profile);
  } catch (error) {
    next(error);
  }
});

module.exports = router;
