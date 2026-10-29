'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateBody, validateQuery } = require('../lib/validate');
const distributions = require('../services/distributions');
const quantities = require('../services/quantities');
const { authenticate, requireRole } = require('../middleware/authenticate');
const { adminWriteLimiter } = require('../middleware/auth-rate-limit');

const router = express.Router();

const MAX_INT = 2147483647;

// Every distribution route requires a valid token for an active ADMIN or
// RESPONSIBLE account; volunteers are rejected with 403.
const ACCESS_ROLES = ['ADMIN', 'RESPONSIBLE'];

const CREATE_FIELDS = {
  locationId: { type: 'int', min: 1, max: MAX_INT },
  variantId: { type: 'int', min: 1, max: MAX_INT },
  quantity: { type: 'int', min: 1, max: MAX_INT },
  recipient: { type: 'string', min: 1, max: 160, collapse: true, required: false, nullable: true },
  note: { type: 'string', min: 1, max: 255, collapse: true, required: false, nullable: true },
};

const UPDATE_FIELDS = {
  quantity: { type: 'int', min: 1, max: MAX_INT, required: false },
  recipient: { type: 'string', min: 1, max: 160, collapse: true, required: false, nullable: true },
  note: { type: 'string', min: 1, max: 255, collapse: true, required: false, nullable: true },
};

const LIST_QUERY = {
  locationId: { type: 'int', min: 1, required: false },
  variantId: { type: 'int', min: 1, required: false },
  productId: { type: 'int', min: 1, required: false },
  dateFrom: { type: 'date', required: false },
  dateTo: { type: 'date', required: false },
};

function parseDistributionId(raw) {
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new AppError(400, 'VALIDATION_ERROR', 'distributionId must be a positive integer.');
  }
  const id = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError(400, 'VALIDATION_ERROR', 'distributionId must be a positive integer.');
  }
  return id;
}

function distributionNotFound() {
  return new AppError(404, 'NOT_FOUND', 'Distribution not found.');
}

function forbidden() {
  return new AppError(403, 'FORBIDDEN', 'You do not have permission to perform this action.');
}

// RESPONSIBLE may only access assigned locations; ADMIN is unrestricted.
async function assertLocationAccess(user, locationId) {
  if (user.role === 'ADMIN') return;
  const assigned = await quantities.isResponsibleForLocation(user.id, locationId);
  if (!assigned) throw forbidden();
}

// ADMIN/RESPONSIBLE: list distribution events, scoped for RESPONSIBLE.
router.get('/', authenticate, requireRole(...ACCESS_ROLES), async (req, res, next) => {
  try {
    const query = validateQuery(req.query, LIST_QUERY);

    // ISO `YYYY-MM-DD` strings compare correctly as plain text.
    if (
      query.dateFrom !== undefined &&
      query.dateTo !== undefined &&
      query.dateFrom > query.dateTo
    ) {
      throw new AppError(400, 'VALIDATION_ERROR', 'dateFrom must not be after dateTo.');
    }

    let responsibleUserId;
    if (req.user.role === 'RESPONSIBLE') {
      if (query.locationId !== undefined) {
        await assertLocationAccess(req.user, query.locationId);
      }
      responsibleUserId = req.user.id;
    }

    const rows = await distributions.listDistributions({
      locationId: query.locationId,
      variantId: query.variantId,
      productId: query.productId,
      dateFrom: query.dateFrom,
      dateTo: query.dateTo,
      responsibleUserId,
    });
    res.status(200).json({ distributions: rows.map(distributions.toSafeDistribution) });
  } catch (error) {
    next(error);
  }
});

// ADMIN/RESPONSIBLE: read one distribution event.
router.get(
  '/:distributionId',
  authenticate,
  requireRole(...ACCESS_ROLES),
  async (req, res, next) => {
    try {
      const distributionId = parseDistributionId(req.params.distributionId);
      const row = await distributions.findDistributionById(distributionId);
      if (!row) throw distributionNotFound();

      await assertLocationAccess(req.user, row.location_id);
      res.status(200).json(distributions.toSafeDistribution(row));
    } catch (error) {
      next(error);
    }
  }
);

// ADMIN/assigned RESPONSIBLE: record a distribution event. The distributor is
// always the authenticated user; it is never taken from the body.
router.post(
  '/',
  authenticate,
  requireRole(...ACCESS_ROLES),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const body = validateBody(req.body || {}, CREATE_FIELDS);
      await assertLocationAccess(req.user, body.locationId);

      const row = await distributions.createDistribution({
        locationId: body.locationId,
        variantId: body.variantId,
        quantity: body.quantity,
        recipient: body.recipient === undefined ? null : body.recipient,
        note: body.note === undefined ? null : body.note,
        distributedBy: req.user.id,
      });

      res.status(201).json(distributions.toSafeDistribution(row));
    } catch (error) {
      next(error);
    }
  }
);

// ADMIN/assigned RESPONSIBLE: correct an existing distribution's quantity,
// recipient and/or note. The owning location is read from the record, never
// from the request body, and linked entities need not remain active.
router.patch(
  '/:distributionId',
  authenticate,
  requireRole(...ACCESS_ROLES),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const distributionId = parseDistributionId(req.params.distributionId);
      const body = validateBody(req.body || {}, UPDATE_FIELDS);

      const fields = {};
      if (body.quantity !== undefined) fields.quantity = body.quantity;
      if (body.recipient !== undefined) fields.recipient = body.recipient;
      if (body.note !== undefined) fields.note = body.note;

      if (Object.keys(fields).length === 0) {
        throw new AppError(
          400,
          'VALIDATION_ERROR',
          'Provide at least one of quantity, recipient or note.'
        );
      }

      const existing = await distributions.findDistributionById(distributionId);
      if (!existing) throw distributionNotFound();

      await assertLocationAccess(req.user, existing.location_id);

      const row = await distributions.updateDistribution(distributionId, fields);
      res.status(200).json(distributions.toSafeDistribution(row));
    } catch (error) {
      next(error);
    }
  }
);

module.exports = router;
