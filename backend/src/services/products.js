'use strict';

const { pool } = require('../db');
const { AppError } = require('../lib/errors');

const PRODUCT_COLUMNS = 'product_id, name, category, is_active';
const VARIANT_COLUMNS = 'variant_id, product_id, unit_label, unit_value, is_active';

// Safe product shape. Never exposes timestamps or raw rows.
function toSafeProduct(row) {
  return {
    id: row.product_id,
    name: row.name,
    category: row.category === undefined ? null : row.category,
    isActive: Boolean(row.is_active),
  };
}

// Safe variant shape. unit_value is DECIMAL(10,3); mysql2 returns it as a string,
// so it is normalised to a number (or null) for a predictable JSON contract.
function toSafeVariant(row) {
  return {
    id: row.variant_id,
    productId: row.product_id,
    unitLabel: row.unit_label,
    unitValue:
      row.unit_value === null || row.unit_value === undefined
        ? null
        : Number(row.unit_value),
    isActive: Boolean(row.is_active),
  };
}

// Active products only, ordered deterministically by name then id.
async function listActiveProducts() {
  const [rows] = await pool.query(
    `SELECT ${PRODUCT_COLUMNS} FROM products
      WHERE is_active = 1
      ORDER BY name ASC, product_id ASC`
  );
  return rows;
}

async function findActiveProductById(productId) {
  const [rows] = await pool.query(
    `SELECT ${PRODUCT_COLUMNS} FROM products
      WHERE product_id = ? AND is_active = 1 LIMIT 1`,
    [productId]
  );
  return rows[0] || null;
}

async function findProductById(productId) {
  const [rows] = await pool.query(
    `SELECT ${PRODUCT_COLUMNS} FROM products WHERE product_id = ? LIMIT 1`,
    [productId]
  );
  return rows[0] || null;
}

// Insert a product as active. On a duplicate-name race this returns
// { created: false } instead of surfacing a raw SQL error.
async function createProduct({ name, category = null }) {
  try {
    const [result] = await pool.query(
      'INSERT INTO products (name, category, is_active) VALUES (?, ?, 1)',
      [name, category]
    );
    return { created: true, productId: result.insertId };
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { created: false, productId: null };
    }
    throw error;
  }
}

// Partial update of name/category. Only active products are editable; omitted
// fields are left unchanged. SQL fragments come from a fixed allowlist.
async function updateProduct(productId, fields) {
  const existing = await findActiveProductById(productId);
  if (!existing) return { found: false };

  const sets = [];
  const values = [];
  if (fields.name !== undefined) {
    sets.push('name = ?');
    values.push(fields.name);
  }
  if (fields.category !== undefined) {
    sets.push('category = ?');
    values.push(fields.category);
  }

  values.push(productId);
  try {
    await pool.query(
      `UPDATE products SET ${sets.join(', ')} WHERE product_id = ? AND is_active = 1`,
      values
    );
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { found: true, updated: false };
    }
    throw error;
  }

  const product = await findProductById(productId);
  return { found: true, updated: true, product };
}

// Archive/reactivate using is_active only. Records are never deleted and
// variants are left untouched. Repeating the current state is a no-op.
async function setProductActiveStatus(productId, isActive) {
  const existing = await findProductById(productId);
  if (!existing) return { found: false };

  if (Boolean(existing.is_active) === isActive) {
    return { found: true, product: existing };
  }

  try {
    await pool.query('UPDATE products SET is_active = ? WHERE product_id = ?', [
      isActive ? 1 : 0,
      productId,
    ]);
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { found: true, duplicate: true };
    }
    throw error;
  }

  const product = await findProductById(productId);
  return { found: true, product };
}

// Active variants of a product, ordered deterministically.
async function listActiveVariants(productId) {
  const [rows] = await pool.query(
    `SELECT ${VARIANT_COLUMNS} FROM product_variants
      WHERE product_id = ? AND is_active = 1
      ORDER BY unit_label ASC, variant_id ASC`,
    [productId]
  );
  return rows;
}

async function findActiveVariantForProduct(productId, variantId) {
  const [rows] = await pool.query(
    `SELECT ${VARIANT_COLUMNS} FROM product_variants
      WHERE variant_id = ? AND product_id = ? AND is_active = 1 LIMIT 1`,
    [variantId, productId]
  );
  return rows[0] || null;
}

async function findVariantForProduct(productId, variantId) {
  const [rows] = await pool.query(
    `SELECT ${VARIANT_COLUMNS} FROM product_variants
      WHERE variant_id = ? AND product_id = ? LIMIT 1`,
    [variantId, productId]
  );
  return rows[0] || null;
}

// Create a variant for an active product. The parent row is locked FOR UPDATE
// first so a variant cannot be created under a concurrently archived product.
// A duplicate unit_label race returns { created: false }.
async function createVariant(productId, { unitLabel, unitValue = null }) {
  const connection = await pool.getConnection();
  let variant;
  try {
    await connection.beginTransaction();

    const [productRows] = await connection.query(
      'SELECT product_id FROM products WHERE product_id = ? AND is_active = 1 FOR UPDATE',
      [productId]
    );
    if (!productRows[0]) {
      throw new AppError(404, 'NOT_FOUND', 'Product not found.');
    }

    let result;
    try {
      [result] = await connection.query(
        `INSERT INTO product_variants (product_id, unit_label, unit_value, is_active)
         VALUES (?, ?, ?, 1)`,
        [productId, unitLabel, unitValue]
      );
    } catch (error) {
      if (error && error.code === 'ER_DUP_ENTRY') {
        await connection.rollback();
        return { created: false, variant: null };
      }
      throw error;
    }

    await connection.commit();
    variant = await findVariantForProduct(productId, result.insertId);
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

  return { created: true, variant };
}

// Partial update of a variant under an active product/active variant. Omitted
// fields are left unchanged; SQL fragments come from a fixed allowlist.
async function updateVariant(productId, variantId, fields) {
  const product = await findActiveProductById(productId);
  if (!product) return { found: false };

  const existing = await findActiveVariantForProduct(productId, variantId);
  if (!existing) return { found: false };

  const sets = [];
  const values = [];
  if (fields.unitLabel !== undefined) {
    sets.push('unit_label = ?');
    values.push(fields.unitLabel);
  }
  if (fields.unitValue !== undefined) {
    sets.push('unit_value = ?');
    values.push(fields.unitValue);
  }

  values.push(variantId, productId);
  try {
    await pool.query(
      `UPDATE product_variants SET ${sets.join(', ')}
        WHERE variant_id = ? AND product_id = ? AND is_active = 1`,
      values
    );
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { found: true, updated: false };
    }
    throw error;
  }

  const variant = await findVariantForProduct(productId, variantId);
  return { found: true, updated: true, variant };
}

// Archive/reactivate a variant using is_active only. The parent product must
// exist (in any state) but is not otherwise modified.
async function setVariantActiveStatus(productId, variantId, isActive) {
  const product = await findProductById(productId);
  if (!product) return { found: false };

  const existing = await findVariantForProduct(productId, variantId);
  if (!existing) return { found: false };

  if (Boolean(existing.is_active) === isActive) {
    return { found: true, variant: existing };
  }

  try {
    await pool.query(
      'UPDATE product_variants SET is_active = ? WHERE variant_id = ? AND product_id = ?',
      [isActive ? 1 : 0, variantId, productId]
    );
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      return { found: true, duplicate: true };
    }
    throw error;
  }

  const variant = await findVariantForProduct(productId, variantId);
  return { found: true, variant };
}

module.exports = {
  PRODUCT_COLUMNS,
  VARIANT_COLUMNS,
  toSafeProduct,
  toSafeVariant,
  listActiveProducts,
  findActiveProductById,
  findProductById,
  createProduct,
  updateProduct,
  setProductActiveStatus,
  listActiveVariants,
  findActiveVariantForProduct,
  findVariantForProduct,
  createVariant,
  updateVariant,
  setVariantActiveStatus,
};
