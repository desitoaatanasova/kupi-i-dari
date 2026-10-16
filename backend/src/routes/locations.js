'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateBody } = require('../lib/validate');
const locations = require('../services/locations');
const users = require('../services/users');
const { authenticate, requireRole } = require('../middleware/authenticate');
const { adminWriteLimiter } = require('../middleware/auth-rate-limit');

const router = express.Router();

const MAX_RESPONSIBLES = 100;

function parseLocationId(raw) {
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new AppError(400, 'VALIDATION_ERROR', 'locationId must be a positive integer.');
  }
  const id = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError(400, 'VALIDATION_ERROR', 'locationId must be a positive integer.');
  }
  return id;
}

// Archived locations are indistinguishable from absent ones on public reads.
function notFound() {
  return new AppError(404, 'NOT_FOUND', 'Location not found.');
}

const CREATE_FIELDS = {
  name: { type: 'string', min: 1, max: 120, collapse: true },
  address: { type: 'string', min: 1, max: 255, collapse: true },
};

const UPDATE_FIELDS = {
  name: { type: 'string', min: 1, max: 120, collapse: true, required: false },
  address: { type: 'string', min: 1, max: 255, collapse: true, required: false },
};

// Public: list active collection locations.
router.get('/', async (req, res, next) => {
  try {
    const rows = await locations.listActiveLocations();
    res.status(200).json({ locations: rows.map(locations.toSafeLocation) });
  } catch (error) {
    next(error);
  }
});

// Public: read one active location.
router.get('/:locationId', async (req, res, next) => {
  try {
    let locationId;
    try {
      locationId = parseLocationId(req.params.locationId);
    } catch (error) {
      throw notFound();
    }
    const location = await locations.findActiveById(locationId);
    if (!location) throw notFound();
    res.status(200).json(locations.toSafeLocation(location));
  } catch (error) {
    next(error);
  }
});

// Admin: create a location.
router.post(
  '/',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const body = validateBody(req.body || {}, CREATE_FIELDS);

      const result = await locations.createLocation(body);
      if (!result.created) {
        throw new AppError(409, 'NAME_TAKEN', 'A location with this name already exists.');
      }
      const location = await locations.findById(result.locationId);
      res.status(201).json(locations.toSafeLocation(location));
    } catch (error) {
      next(error);
    }
  }
);

// Admin: partial update of name and/or address.
router.patch(
  '/:locationId',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const locationId = parseLocationId(req.params.locationId);
      const body = validateBody(req.body || {}, UPDATE_FIELDS);

      const fields = {};
      if (body.name !== undefined) fields.name = body.name;
      if (body.address !== undefined) fields.address = body.address;

      if (Object.keys(fields).length === 0) {
        throw new AppError(400, 'VALIDATION_ERROR', 'Provide at least one of name or address.');
      }

      const result = await locations.updateLocation(locationId, fields);
      if (!result.found) throw notFound();
      if (!result.updated) {
        throw new AppError(409, 'NAME_TAKEN', 'A location with this name already exists.');
      }
      res.status(200).json(locations.toSafeLocation(result.location));
    } catch (error) {
      next(error);
    }
  }
);

// Admin: archive or reactivate a location.
router.patch(
  '/:locationId/status',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const locationId = parseLocationId(req.params.locationId);
      const body = validateBody(req.body || {}, { isActive: { type: 'boolean' } });

      const result = await locations.setActiveStatus(locationId, body.isActive);
      if (!result.found) throw notFound();
      if (result.duplicate) {
        throw new AppError(409, 'NAME_TAKEN', 'A location with this name already exists.');
      }
      res.status(200).json(locations.toSafeLocation(result.location));
    } catch (error) {
      next(error);
    }
  }
);

// Admin: list assigned responsibles (read — no write limiter).
router.get('/:locationId/responsibles', authenticate, requireRole('ADMIN'), async (req, res, next) => {
  try {
    const locationId = parseLocationId(req.params.locationId);
    const location = await locations.findActiveById(locationId);
    if (!location) throw notFound();

    const rows = await locations.listResponsibles(locationId);
    res.status(200).json({ responsibles: rows.map(users.toSafeProfile) });
  } catch (error) {
    next(error);
  }
});

// Admin: atomically replace the responsible set.
router.put(
  '/:locationId/responsibles',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const locationId = parseLocationId(req.params.locationId);
      const body = validateBody(req.body || {}, {
        userIds: { type: 'intArray', maxItems: MAX_RESPONSIBLES },
      });

      const rows = await locations.replaceResponsibles(locationId, body.userIds);
      res.status(200).json({ responsibles: rows.map(users.toSafeProfile) });
    } catch (error) {
      next(error);
    }
  }
);

module.exports = router;
