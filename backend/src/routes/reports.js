'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateQuery } = require('../lib/validate');
const reports = require('../services/reports');
const quantities = require('../services/quantities');
const { authenticate, requireRole } = require('../middleware/authenticate');

const router = express.Router();

// Reports are operational staff reads: ADMIN and RESPONSIBLE only. Volunteers
// are rejected with 403.
const ACCESS_ROLES = ['ADMIN', 'RESPONSIBLE'];

const COLLECTED_QUERY = {
  shiftId: { type: 'int', min: 1, required: false },
  locationId: { type: 'int', min: 1, required: false },
  productId: { type: 'int', min: 1, required: false },
  dateFrom: { type: 'date', required: false },
  dateTo: { type: 'date', required: false },
};

// Inventory balance report has no shift filter: distributions are not linked to
// shifts, so a shift scope would be asymmetric and misleading.
const INVENTORY_QUERY = {
  locationId: { type: 'int', min: 1, required: false },
  productId: { type: 'int', min: 1, required: false },
  variantId: { type: 'int', min: 1, required: false },
  dateFrom: { type: 'date', required: false },
  dateTo: { type: 'date', required: false },
};

function forbidden() {
  return new AppError(403, 'FORBIDDEN', 'You do not have permission to perform this action.');
}

// ADMIN/RESPONSIBLE: aggregate report of recorded quantities, grouped by
// location and product. RESPONSIBLE is scoped to assigned locations; an
// explicit unassigned location is a permission error (matching /api/quantities).
router.get('/collected', authenticate, requireRole(...ACCESS_ROLES), async (req, res, next) => {
  try {
    const query = validateQuery(req.query, COLLECTED_QUERY);

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
        const assigned = await quantities.isResponsibleForLocation(
          req.user.id,
          query.locationId
        );
        if (!assigned) throw forbidden();
      }
      responsibleUserId = req.user.id;
    }

    const report = await reports.sumCollected({
      filters: {
        shiftId: query.shiftId,
        locationId: query.locationId,
        productId: query.productId,
        dateFrom: query.dateFrom,
        dateTo: query.dateTo,
      },
      responsibleUserId,
    });

    res.status(200).json(report);
  } catch (error) {
    next(error);
  }
});

// ADMIN/RESPONSIBLE: collected minus distributed per (location, variant), with
// totals and per-location/product/variant roll-ups. RESPONSIBLE is scoped to
// assigned locations on BOTH sides; an explicit unassigned location is a
// permission error (matching /api/reports/collected). Remaining quantities may
// be negative and are never clamped.
router.get('/inventory', authenticate, requireRole(...ACCESS_ROLES), async (req, res, next) => {
  try {
    const query = validateQuery(req.query, INVENTORY_QUERY);

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
        const assigned = await quantities.isResponsibleForLocation(
          req.user.id,
          query.locationId
        );
        if (!assigned) throw forbidden();
      }
      responsibleUserId = req.user.id;
    }

    const report = await reports.sumInventory({
      filters: {
        locationId: query.locationId,
        productId: query.productId,
        variantId: query.variantId,
        dateFrom: query.dateFrom,
        dateTo: query.dateTo,
      },
      responsibleUserId,
    });

    res.status(200).json(report);
  } catch (error) {
    next(error);
  }
});

module.exports = router;