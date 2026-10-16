'use strict';

const express = require('express');

const { AppError } = require('../lib/errors');
const { validateBody } = require('../lib/validate');
const products = require('../services/products');
const { authenticate, requireRole } = require('../middleware/authenticate');
const { adminWriteLimiter } = require('../middleware/auth-rate-limit');

const router = express.Router();

function parsePositiveId(raw, label) {
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new AppError(400, 'VALIDATION_ERROR', `${label} must be a positive integer.`);
  }
  const id = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError(400, 'VALIDATION_ERROR', `${label} must be a positive integer.`);
  }
  return id;
}

const parseProductId = (raw) => parsePositiveId(raw, 'productId');
const parseVariantId = (raw) => parsePositiveId(raw, 'variantId');

// Archived records are indistinguishable from absent ones on public reads.
function productNotFound() {
  return new AppError(404, 'NOT_FOUND', 'Product not found.');
}

function variantNotFound() {
  return new AppError(404, 'NOT_FOUND', 'Variant not found.');
}

function nameTaken() {
  return new AppError(409, 'NAME_TAKEN', 'A product with this name already exists.');
}

function labelTaken() {
  return new AppError(
    409,
    'LABEL_TAKEN',
    'A variant with this unit label already exists for this product.'
  );
}

const CREATE_PRODUCT_FIELDS = {
  name: { type: 'string', min: 1, max: 120, collapse: true },
  category: { type: 'string', min: 1, max: 80, collapse: true, required: false, nullable: true },
};

const UPDATE_PRODUCT_FIELDS = {
  name: { type: 'string', min: 1, max: 120, collapse: true, required: false },
  category: { type: 'string', min: 1, max: 80, collapse: true, required: false, nullable: true },
};

const CREATE_VARIANT_FIELDS = {
  unitLabel: { type: 'string', min: 1, max: 40, collapse: true },
  unitValue: { type: 'decimal', required: false, nullable: true },
};

const UPDATE_VARIANT_FIELDS = {
  unitLabel: { type: 'string', min: 1, max: 40, collapse: true, required: false },
  unitValue: { type: 'decimal', required: false, nullable: true },
};

// Public: list active products.
router.get('/', async (req, res, next) => {
  try {
    const rows = await products.listActiveProducts();
    res.status(200).json({ products: rows.map(products.toSafeProduct) });
  } catch (error) {
    next(error);
  }
});

// Public: read one active product.
router.get('/:productId', async (req, res, next) => {
  try {
    let productId;
    try {
      productId = parseProductId(req.params.productId);
    } catch (error) {
      throw productNotFound();
    }
    const product = await products.findActiveProductById(productId);
    if (!product) throw productNotFound();
    res.status(200).json(products.toSafeProduct(product));
  } catch (error) {
    next(error);
  }
});

// Admin: create a product.
router.post('/', authenticate, requireRole('ADMIN'), adminWriteLimiter, async (req, res, next) => {
  try {
    const body = validateBody(req.body || {}, CREATE_PRODUCT_FIELDS);

    const result = await products.createProduct({
      name: body.name,
      category: body.category === undefined ? null : body.category,
    });
    if (!result.created) throw nameTaken();

    const product = await products.findProductById(result.productId);
    res.status(201).json(products.toSafeProduct(product));
  } catch (error) {
    next(error);
  }
});

// Admin: partial update of name and/or category (category may be cleared).
router.patch(
  '/:productId',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const productId = parseProductId(req.params.productId);
      const body = validateBody(req.body || {}, UPDATE_PRODUCT_FIELDS);

      const fields = {};
      if (body.name !== undefined) fields.name = body.name;
      if (body.category !== undefined) fields.category = body.category;

      if (Object.keys(fields).length === 0) {
        throw new AppError(400, 'VALIDATION_ERROR', 'Provide at least one of name or category.');
      }

      const result = await products.updateProduct(productId, fields);
      if (!result.found) throw productNotFound();
      if (!result.updated) throw nameTaken();
      res.status(200).json(products.toSafeProduct(result.product));
    } catch (error) {
      next(error);
    }
  }
);

// Admin: archive or reactivate a product.
router.patch(
  '/:productId/status',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const productId = parseProductId(req.params.productId);
      const body = validateBody(req.body || {}, { isActive: { type: 'boolean' } });

      const result = await products.setProductActiveStatus(productId, body.isActive);
      if (!result.found) throw productNotFound();
      if (result.duplicate) throw nameTaken();
      res.status(200).json(products.toSafeProduct(result.product));
    } catch (error) {
      next(error);
    }
  }
);

// Public: list active variants of an active product.
router.get('/:productId/variants', async (req, res, next) => {
  try {
    let productId;
    try {
      productId = parseProductId(req.params.productId);
    } catch (error) {
      throw productNotFound();
    }
    const product = await products.findActiveProductById(productId);
    if (!product) throw productNotFound();

    const rows = await products.listActiveVariants(productId);
    res.status(200).json({ variants: rows.map(products.toSafeVariant) });
  } catch (error) {
    next(error);
  }
});

// Admin: create a variant for an active product.
router.post(
  '/:productId/variants',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const productId = parseProductId(req.params.productId);
      const body = validateBody(req.body || {}, CREATE_VARIANT_FIELDS);

      const result = await products.createVariant(productId, {
        unitLabel: body.unitLabel,
        unitValue: body.unitValue === undefined ? null : body.unitValue,
      });
      if (!result.created) throw labelTaken();

      res.status(201).json(products.toSafeVariant(result.variant));
    } catch (error) {
      next(error);
    }
  }
);

// Admin: partial update of a variant under the addressed product.
router.patch(
  '/:productId/variants/:variantId',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const productId = parseProductId(req.params.productId);
      const variantId = parseVariantId(req.params.variantId);
      const body = validateBody(req.body || {}, UPDATE_VARIANT_FIELDS);

      const fields = {};
      if (body.unitLabel !== undefined) fields.unitLabel = body.unitLabel;
      if (body.unitValue !== undefined) fields.unitValue = body.unitValue;

      if (Object.keys(fields).length === 0) {
        throw new AppError(
          400,
          'VALIDATION_ERROR',
          'Provide at least one of unitLabel or unitValue.'
        );
      }

      const result = await products.updateVariant(productId, variantId, fields);
      if (!result.found) throw variantNotFound();
      if (!result.updated) throw labelTaken();
      res.status(200).json(products.toSafeVariant(result.variant));
    } catch (error) {
      next(error);
    }
  }
);

// Admin: archive or reactivate a variant.
router.patch(
  '/:productId/variants/:variantId/status',
  authenticate,
  requireRole('ADMIN'),
  adminWriteLimiter,
  async (req, res, next) => {
    try {
      const productId = parseProductId(req.params.productId);
      const variantId = parseVariantId(req.params.variantId);
      const body = validateBody(req.body || {}, { isActive: { type: 'boolean' } });

      const result = await products.setVariantActiveStatus(productId, variantId, body.isActive);
      if (!result.found) throw variantNotFound();
      if (result.duplicate) throw labelTaken();
      res.status(200).json(products.toSafeVariant(result.variant));
    } catch (error) {
      next(error);
    }
  }
);

module.exports = router;
