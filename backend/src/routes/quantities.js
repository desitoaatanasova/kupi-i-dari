'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateBody, validateQuery } = require('../lib/validate');
const quantities = require('../services/quantities');
const { authenticate, requireRole } = require('../middleware/authenticate');
const { adminWriteLimiter } = require('../middleware/auth-rate-limit');

const router = express.Router();

const MAX_INT = 2147483647;

// Every quantity route requires a valid token for an active ADMIN or
// RESPONSIBLE account; volunteers are rejected with 403.
const ACCESS_ROLES = ['ADMIN', 'RESPONSIBLE'];

const CREATE_FIELDS = {
  locationId: { type: 'int', min: 1, max: MAX_INT },
  variantId: { type: 'int', min: 1, max: MAX_INT },
  quantity: { type: 'int', min: 0, max: MAX_INT },
  shiftId: { type: 'int', min: 1, max: MAX_INT, required: false, nullable: true },
};

const UPDATE_FIELDS = {
  quantity: { type: 'int', min: 0, max: MAX_INT },
};

const LIST_QUERY = {
  locationId: { type: 'int', min: 1, required: false },
  variantId: { type: 'int', min: 1, required: false },
  productId: { type: 'int', min: 1, required: false },
  shiftId: { type: 'int', min: 1, required: false },
};

function parseQuantityId(raw) {
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new AppError(400, 'VALIDATION_ERROR', 'quantityId must be a positive integer.');
  }
  const id = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError(400, 'VALIDATION_ERROR', 'quantityId must be a positive integer.');
  }
  return id;
}

function quantityNotFound() {
  return new AppError(404, 'NOT_FOUND', 'Quantity record not found.');
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

// ADMIN/RESPONSIBLE: list quantity records (optionally filtered).
router.get('/', authenticate, requireRole(...ACCESS_ROLES), async (req, res, next) => {
  try {
    const query = validateQuery(req.query, LIST_QUERY);

    let responsibleUserId;
    if (req.user.role === 'RESPONSIBLE') {
      // An explicit unassigned location is a permission error, not an empty page.
      if (query.locationId !== undefined) {
        const assigned = await quantities.isResponsibleForLocation(
          req.user.id,
          query.locationId
        );
        if (!assigned) throw forbidden();
      }
      responsibleUserId = req.user.id;
    }

    const rows = await quantities.listQuantities({
      locationId: query.locationId,
      variantId: query.variantId,
      productId: query.productId,
      shiftId: query.shiftId,
      responsibleUserId,
    });
    res.status(200).json({ quantities: rows.map(quantities.toSafeQuantity) });
  } catch (error) {
    next(error);
  }
});

// ADMIN/RESPONSIBLE: read one quantity record.
router.get('/:quantityId', authenticate, requireRole(...ACCESS_ROLES), async (req, res, next) => {
  try {
    const quantityId = parseQuantityId(req.params.quantityId);
    const row = await quantities.findQuantityById(quantityId);
    if (!row) throw quantityNotFound();

    await assertLocationAccess(req.user, row.location_id);
    res.status(200).json(quantities.toSafeQuantity(row));
  } catch (error) {
    next(error);
  }
});

// ADMIN/assigned RESPONSIBLE: create or replace a quantity. Without `shiftId`
// the row is unlinked (legacy per-location model); with `shiftId` it is a
// distinct shift-linked row. Staff writes are not gated by the volunteer
// entry window or registration rules.
router.post(
  '/',
  authenticate,
  requireRole(...ACCESS_ROLES),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const body = validateBody(req.body || {}, CREATE_FIELDS);
      await assertLocationAccess(req.user, body.locationId);

      const result = await quantities.upsertQuantity({
        locationId: body.locationId,
        variantId: body.variantId,
        quantity: body.quantity,
        recordedBy: req.user.id,
        shiftId: body.shiftId === undefined ? null : body.shiftId,
      });

      res.status(result.created ? 201 : 200).json(quantities.toSafeQuantity(result.quantity));
    } catch (error) {
      next(error);
    }
  }
);

// ADMIN/assigned RESPONSIBLE: replace an existing record's quantity absolutely.
// Linked entities are not required to remain active (see the service).
router.patch(
  '/:quantityId',
  authenticate,
  requireRole(...ACCESS_ROLES),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const quantityId = parseQuantityId(req.params.quantityId);
      const body = validateBody(req.body || {}, UPDATE_FIELDS);

      const existing = await quantities.findQuantityById(quantityId);
      if (!existing) throw quantityNotFound();

      await assertLocationAccess(req.user, existing.location_id);

      const row = await quantities.setQuantityValue(quantityId, body.quantity, req.user.id);
      res.status(200).json(quantities.toSafeQuantity(row));
    } catch (error) {
      next(error);
    }
  }
);

module.exports = router;
