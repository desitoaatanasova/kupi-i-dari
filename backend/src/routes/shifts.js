'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateBody, validateQuery } = require('../lib/validate');
const shifts = require('../services/shifts');
const locations = require('../services/locations');
const { authenticate, requireRole } = require('../middleware/authenticate');
const { adminWriteLimiter } = require('../middleware/auth-rate-limit');

const router = express.Router();

const MAX_LOCATIONS = 100;
const STATUS_VALUES = ['DRAFT', 'OPEN', 'CLOSED', 'CANCELLED'];

const CREATE_FIELDS = {
  title: { type: 'string', min: 1, max: 120, collapse: true, required: false, nullable: true },
  date: { type: 'date' },
  startTime: { type: 'time' },
  endTime: { type: 'time' },
  locationIds: {
    type: 'intArray',
    minItems: 1,
    maxItems: MAX_LOCATIONS,
  },
};

const UPDATE_FIELDS = {
  title: { type: 'string', min: 1, max: 120, collapse: true, required: false, nullable: true },
  date: { type: 'date', required: false },
  startTime: { type: 'time', required: false },
  endTime: { type: 'time', required: false },
};

const LIST_QUERY = {
  status: { type: 'enum', values: STATUS_VALUES, required: false },
  date: { type: 'date', required: false },
};

function parseShiftId(raw) {
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new AppError(400, 'VALIDATION_ERROR', 'shiftId must be a positive integer.');
  }
  const id = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError(400, 'VALIDATION_ERROR', 'shiftId must be a positive integer.');
  }
  return id;
}

function parseRegistrationId(raw) {
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new AppError(400, 'VALIDATION_ERROR', 'registrationId must be a positive integer.');
  }
  const id = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError(400, 'VALIDATION_ERROR', 'registrationId must be a positive integer.');
  }
  return id;
}

// Missing, malformed and hidden records are indistinguishable on reads.
function shiftNotFound() {
  return new AppError(404, 'NOT_FOUND', 'Shift not found.');
}

function forbidden() {
  return new AppError(403, 'FORBIDDEN', 'You do not have permission to perform this action.');
}

// Attach the shift's safe location list to a safe shift object.
async function withLocations(shift) {
  const rows = await shifts.listShiftLocations(shift.id);
  return { ...shift, locations: rows.map(locations.toSafeLocation) };
}

// Any authenticated user: list shifts. Volunteers never see DRAFT shifts.
router.get('/', authenticate, async (req, res, next) => {
  try {
    const query = validateQuery(req.query, LIST_QUERY);
    const rows = await shifts.listShifts({
      status: query.status,
      date: query.date,
      includeDraft: req.user.role !== 'VOLUNTEER',
    });
    res.status(200).json({ shifts: rows.map(shifts.toSafeShift) });
  } catch (error) {
    next(error);
  }
});

// Any authenticated user: read a shift with its locations. Volunteers cannot
// see DRAFT shifts (indistinguishable from absent). Includes the caller's own
// registration status.
router.get('/:shiftId', authenticate, async (req, res, next) => {
  try {
    let shiftId;
    try {
      shiftId = parseShiftId(req.params.shiftId);
    } catch (error) {
      throw shiftNotFound();
    }

    const row = await shifts.findShiftById(shiftId);
    if (!row) throw shiftNotFound();
    if (req.user.role === 'VOLUNTEER' && row.status === 'DRAFT') throw shiftNotFound();

    const shift = await withLocations(shifts.toSafeShift(row));
    const registration = await shifts.findRegistrationForUser(shiftId, req.user.id);
    res.status(200).json({
      ...shift,
      myRegistration: registration ? { status: registration.status } : null,
    });
  } catch (error) {
    next(error);
  }
});

// Admin: create a DRAFT shift with at least one active location.
router.post(
  '/',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const body = validateBody(req.body || {}, CREATE_FIELDS);

      const result = await shifts.createShift({
        title: body.title === undefined ? null : body.title,
        date: body.date,
        startTime: body.startTime,
        endTime: body.endTime,
        locationIds: body.locationIds,
        createdBy: req.user.id,
      });

      const shift = await shifts.findShiftById(result.shiftId);
      res.status(201).json(await withLocations(shifts.toSafeShift(shift)));
    } catch (error) {
      next(error);
    }
  }
);

// Admin: partial update of title/date/times while DRAFT or OPEN.
router.patch(
  '/:shiftId',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const shiftId = parseShiftId(req.params.shiftId);
      const body = validateBody(req.body || {}, UPDATE_FIELDS);

      const fields = {};
      if (body.title !== undefined) fields.title = body.title;
      if (body.date !== undefined) fields.date = body.date;
      if (body.startTime !== undefined) fields.startTime = body.startTime;
      if (body.endTime !== undefined) fields.endTime = body.endTime;

      if (Object.keys(fields).length === 0) {
        throw new AppError(
          400,
          'VALIDATION_ERROR',
          'Provide at least one of title, date, startTime or endTime.'
        );
      }

      const result = await shifts.updateShift(shiftId, fields);
      if (!result.found) throw shiftNotFound();
      if (!result.editable) {
        throw new AppError(
          409,
          'SHIFT_NOT_EDITABLE',
          'This shift is no longer editable.'
        );
      }
      res.status(200).json(result.shift);
    } catch (error) {
      next(error);
    }
  }
);

// Admin: transition a shift's status.
router.patch(
  '/:shiftId/status',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const shiftId = parseShiftId(req.params.shiftId);
      const body = validateBody(req.body || {}, {
        status: { type: 'enum', values: STATUS_VALUES },
      });

      const result = await shifts.setStatus(shiftId, body.status);
      if (!result.found) throw shiftNotFound();
      if (!result.valid) {
        throw new AppError(
          409,
          'INVALID_STATUS_TRANSITION',
          'This status transition is not allowed.'
        );
      }
      res.status(200).json(result.shift);
    } catch (error) {
      next(error);
    }
  }
);

// Admin: atomically replace the shift's location set while DRAFT or OPEN.
router.put(
  '/:shiftId/locations',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const shiftId = parseShiftId(req.params.shiftId);
      const body = validateBody(req.body || {}, {
        locationIds: { type: 'intArray', minItems: 1, maxItems: MAX_LOCATIONS },
      });

      const rows = await shifts.replaceLocations(shiftId, body.locationIds);
      res.status(200).json({ locations: rows.map(locations.toSafeLocation) });
    } catch (error) {
      next(error);
    }
  }
);

// Admin (any shift) or assigned RESPONSIBLE: list registrations. Volunteers
// must never access registration lists.
router.get(
  '/:shiftId/registrations',
  authenticate,
  requireRole('ADMIN', 'RESPONSIBLE'),
  async (req, res, next) => {
    try {
      let shiftId;
      try {
        shiftId = parseShiftId(req.params.shiftId);
      } catch (error) {
        throw shiftNotFound();
      }

      const shift = await shifts.findShiftById(shiftId);
      if (!shift) throw shiftNotFound();

      if (req.user.role === 'RESPONSIBLE') {
        const assigned = await shifts.isResponsibleForShift(shiftId, req.user.id);
        if (!assigned) throw forbidden();
      }

      const rows = await shifts.listRegistrations(shiftId);
      res.status(200).json({ registrations: rows.map(shifts.toSafeRegistration) });
    } catch (error) {
      next(error);
    }
  }
);

// Volunteer: register themselves for an OPEN shift.
router.post(
  '/:shiftId/registrations',
  authenticate,
  requireRole('VOLUNTEER'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const shiftId = parseShiftId(req.params.shiftId);
      validateBody(req.body || {}, {});

      const result = await shifts.registerSelf(shiftId, req.user.id);
      if (!result.found) throw shiftNotFound();
      if (!result.open) {
        throw new AppError(
          409,
          'SHIFT_NOT_OPEN',
          'Registration is only possible while the shift is open.'
        );
      }
      if (result.duplicate) {
        throw new AppError(
          409,
          'ALREADY_REGISTERED',
          'You are already registered for this shift.'
        );
      }

      res
        .status(result.created ? 201 : 200)
        .json(shifts.toSafeRegistration(result.registration));
    } catch (error) {
      next(error);
    }
  }
);

// Volunteer (own registration) or Admin (any): cancel a registration.
router.patch(
  '/:shiftId/registrations/:registrationId/cancel',
  authenticate,
  requireRole('ADMIN', 'VOLUNTEER'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const shiftId = parseShiftId(req.params.shiftId);
      const registrationId = parseRegistrationId(req.params.registrationId);
      validateBody(req.body || {}, {});

      const result = await shifts.cancelRegistration({
        shiftId,
        registrationId,
        userId: req.user.id,
        isAdmin: req.user.role === 'ADMIN',
      });
      if (!result.found) {
        throw new AppError(404, 'NOT_FOUND', 'Registration not found.');
      }
      if (!result.open) {
        throw new AppError(
          409,
          'SHIFT_NOT_OPEN',
          'Registrations can only be changed while the shift is open.'
        );
      }

      res.status(200).json(shifts.toSafeRegistration(result.registration));
    } catch (error) {
      next(error);
    }
  }
);

module.exports = router;
