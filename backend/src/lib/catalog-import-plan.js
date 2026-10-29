'use strict';

const { normalizeText, decimalKey } = require('./catalog-csv');

// Approximate the case-insensitive utf8mb4_unicode_ci comparison used by the
// unique indexes. The importer rechecks every write against MySQL inside the
// transaction, so this key is a dry-run aid, not the final authority.
function collationKey(value) {
  return normalizeText(value).toLocaleLowerCase('bg');
}

function productKey(name) {
  return collationKey(name);
}

function categoryKey(category) {
  return category === null || category === undefined ? '' : collationKey(category);
}

function variantKey(label) {
  return collationKey(label);
}

function currentProduct(product) {
  return {
    productId: product.productId ?? product.product_id,
    name: product.name,
    category: product.category === undefined ? null : product.category,
    isActive: product.isActive ?? Boolean(product.is_active),
  };
}

function currentVariant(variant) {
  return {
    variantId: variant.variantId ?? variant.variant_id,
    productId: variant.productId ?? variant.product_id,
    unitLabel: variant.unitLabel ?? variant.unit_label,
    unitValue: variant.unitValue ?? variant.unit_value,
    isActive: variant.isActive ?? Boolean(variant.is_active),
  };
}

function distinctCounts(values) {
  const counts = new Map();
  for (const value of values) {
    counts.set(value, (counts.get(value) || 0) + 1);
  }
  return [...counts.entries()]
    .map(([value, count]) => ({ value, count }))
    .sort((a, b) => b.count - a.count || String(a.value).localeCompare(String(b.value), 'bg'));
}

function buildImportPlan(rows, existing = {}) {
  const existingProducts = (existing.products || []).map(currentProduct);
  const existingVariants = (existing.variants || []).map(currentVariant);

  const conflicts = [];
  const skippedRows = [];
  const duplicates = [];
  const productsToInsert = [];
  const variantsToInsert = [];
  const matchedProducts = [];
  const matchedVariants = [];

  const productsByKey = new Map();
  for (const product of existingProducts) {
    const key = productKey(product.name);
    if (!productsByKey.has(key)) productsByKey.set(key, product);
  }

  const variantsByProduct = new Map();
  for (const variant of existingVariants) {
    if (!variantsByProduct.has(variant.productId)) {
      variantsByProduct.set(variant.productId, new Map());
    }
    variantsByProduct.get(variant.productId).set(variantKey(variant.unitLabel), variant);
  }

  const groups = new Map();
  for (const row of rows) {
    const key = productKey(row.productName);
    if (!groups.has(key)) {
      groups.set(key, {
        key,
        name: row.productName,
        rows: [],
      });
    }
    groups.get(key).rows.push(row);
  }

  const csvProductKeys = new Set(groups.keys());
  const touchedProductIds = new Set();
  const touchedVariantKeysByProductId = new Map();

  for (const group of groups.values()) {
    const categories = [...new Set(group.rows.map((row) => row.category))];
    const categoryKeys = new Set(categories.map(categoryKey));
    const existingProduct = productsByKey.get(group.key);

    if (existingProduct) {
      touchedProductIds.add(existingProduct.productId);
      touchedVariantKeysByProductId.set(
        existingProduct.productId,
        new Set(group.rows.map((row) => variantKey(row.variantLabel)))
      );
    }

    if (categoryKeys.size > 1) {
      const conflict = {
        code: 'CATEGORY_CONFLICT',
        productKey: group.key,
        productName: group.name,
        lines: group.rows.map((row) => row.line),
        categories,
        message: 'All CSV rows for a product must use the same category.',
      };
      conflicts.push(conflict);
      for (const row of group.rows) {
        skippedRows.push({
          line: row.line,
          productKey: group.key,
          productName: group.name,
          variantKey: variantKey(row.variantLabel),
          reason: conflict.code,
        });
      }
      continue;
    }

    const category = categories[0] === undefined ? null : categories[0];

    if (existingProduct && !existingProduct.isActive) {
      const conflict = {
        code: 'ARCHIVED_PRODUCT',
        productKey: group.key,
        productName: group.name,
        lines: group.rows.map((row) => row.line),
        existingProductId: existingProduct.productId,
        message: 'The product exists but is archived; the importer never reactivates records.',
      };
      conflicts.push(conflict);
      for (const row of group.rows) {
        skippedRows.push({
          line: row.line,
          productKey: group.key,
          productName: group.name,
          variantKey: variantKey(row.variantLabel),
          reason: conflict.code,
        });
      }
      continue;
    }

    if (existingProduct && categoryKey(existingProduct.category) !== categoryKey(category)) {
      const conflict = {
        code: existingProduct.category === null || existingProduct.category === undefined
          ? 'CATEGORY_MISSING'
          : 'CATEGORY_MISMATCH',
        productKey: group.key,
        productName: group.name,
        lines: group.rows.map((row) => row.line),
        existingProductId: existingProduct.productId,
        csvCategory: category,
        existingCategory: existingProduct.category === undefined ? null : existingProduct.category,
        message: existingProduct.category === null || existingProduct.category === undefined
          ? 'The existing product has no category; the importer will not fill it automatically.'
          : 'The existing product has a different category.',
      };
      conflicts.push(conflict);
      for (const row of group.rows) {
        skippedRows.push({
          line: row.line,
          productKey: group.key,
          productName: group.name,
          variantKey: variantKey(row.variantLabel),
          reason: conflict.code,
        });
      }
      continue;
    }

    let productPlan = null;
    let parentProductId = null;

    if (existingProduct) {
      parentProductId = existingProduct.productId;
      matchedProducts.push({
        productKey: group.key,
        productId: existingProduct.productId,
        name: existingProduct.name,
        csvName: group.name,
        category: existingProduct.category === undefined ? null : existingProduct.category,
        lines: group.rows.map((row) => row.line),
      });
    } else {
      productPlan = {
        key: group.key,
        name: group.name,
        category,
        lines: group.rows.map((row) => row.line),
        variants: [],
      };
      productsToInsert.push(productPlan);
    }

    const seenVariants = new Map();
    for (const row of group.rows) {
      const key = variantKey(row.variantLabel);

      if (!seenVariants.has(key)) {
        seenVariants.set(key, {
          key,
          unitLabel: row.variantLabel,
          unitValue: row.unitValue,
          lines: [row.line],
          sourceLabels: row.sourceLabel ? [row.sourceLabel] : [],
        });
        continue;
      }

      const first = seenVariants.get(key);
      if (decimalKey(first.unitValue) !== decimalKey(row.unitValue)) {
        const conflict = {
          code: 'DUPLICATE_VARIANT_CONFLICT',
          productKey: group.key,
          productName: group.name,
          variantKey: key,
          unitLabel: row.variantLabel,
          line: row.line,
          firstLine: first.lines[0],
          unitValues: [first.unitValue, row.unitValue],
          message: 'The same product/variant key appears with incompatible unit values.',
        };
        conflicts.push(conflict);
        skippedRows.push({
          line: row.line,
          productKey: group.key,
          productName: group.name,
          variantKey: key,
          reason: conflict.code,
        });
      } else {
        duplicates.push({
          line: row.line,
          duplicateOfLine: first.lines[0],
          productKey: group.key,
          productName: group.name,
          variantKey: key,
          unitLabel: row.variantLabel,
          unitValue: row.unitValue,
          reason: 'DUPLICATE_ROW',
        });
        skippedRows.push({
          line: row.line,
          productKey: group.key,
          productName: group.name,
          variantKey: key,
          reason: 'DUPLICATE_ROW',
        });
      }
    }

    for (const candidate of seenVariants.values()) {
      const existingVariant = parentProductId === null
        ? null
        : (variantsByProduct.get(parentProductId) || new Map()).get(candidate.key);

      if (existingVariant && !existingVariant.isActive) {
        const conflict = {
          code: 'ARCHIVED_VARIANT',
          productKey: group.key,
          productName: group.name,
          variantKey: candidate.key,
          unitLabel: candidate.unitLabel,
          lines: candidate.lines,
          existingProductId: parentProductId,
          existingVariantId: existingVariant.variantId,
          message: 'The variant exists but is archived; the importer never reactivates records.',
        };
        conflicts.push(conflict);
        for (const line of candidate.lines) {
          skippedRows.push({
            line,
            productKey: group.key,
            productName: group.name,
            variantKey: candidate.key,
            reason: conflict.code,
          });
        }
        continue;
      }

      if (existingVariant && decimalKey(existingVariant.unitValue) !== decimalKey(candidate.unitValue)) {
        const conflict = {
          code: 'UNIT_VALUE_MISMATCH',
          productKey: group.key,
          productName: group.name,
          variantKey: candidate.key,
          unitLabel: candidate.unitLabel,
          lines: candidate.lines,
          existingProductId: parentProductId,
          existingVariantId: existingVariant.variantId,
          csvUnitValue: candidate.unitValue,
          existingUnitValue:
            existingVariant.unitValue === undefined ? null : existingVariant.unitValue,
          message: 'The existing variant has a different unit value.',
        };
        conflicts.push(conflict);
        for (const line of candidate.lines) {
          skippedRows.push({
            line,
            productKey: group.key,
            productName: group.name,
            variantKey: candidate.key,
            reason: conflict.code,
          });
        }
        continue;
      }

      if (existingVariant) {
        matchedVariants.push({
          productKey: group.key,
          productId: parentProductId,
          variantId: existingVariant.variantId,
          unitLabel: existingVariant.unitLabel,
          csvUnitLabel: candidate.unitLabel,
          unitValue: existingVariant.unitValue === undefined ? null : existingVariant.unitValue,
          lines: candidate.lines,
        });
        continue;
      }

      const variantPlan = {
        productKey: group.key,
        productId: parentProductId,
        productName: group.name,
        key: candidate.key,
        unitLabel: candidate.unitLabel,
        unitValue: candidate.unitValue,
        lines: candidate.lines,
        sourceLabels: candidate.sourceLabels,
      };
      variantsToInsert.push(variantPlan);
      if (productPlan) productPlan.variants.push(variantPlan);
    }
  }

  const untouchedProducts = existingProducts
    .filter((product) => !csvProductKeys.has(productKey(product.name)))
    .map((product) => ({
      productId: product.productId,
      name: product.name,
      category: product.category === undefined ? null : product.category,
      isActive: product.isActive,
    }));

  const untouchedVariants = existingVariants
    .filter((variant) => {
      if (!touchedProductIds.has(variant.productId)) return true;
      const keys = touchedVariantKeysByProductId.get(variant.productId);
      return !keys || !keys.has(variantKey(variant.unitLabel));
    })
    .map((variant) => ({
      variantId: variant.variantId,
      productId: variant.productId,
      unitLabel: variant.unitLabel,
      unitValue: variant.unitValue === undefined ? null : variant.unitValue,
      isActive: variant.isActive,
    }));

  const categoryCounts = new Map();
  for (const row of rows) {
    categoryCounts.set(row.category, (categoryCounts.get(row.category) || 0) + 1);
  }

  return {
    ok: conflicts.length === 0,
    groups: groups.size,
    productsToInsert,
    variantsToInsert,
    matchedProducts,
    matchedVariants,
    duplicates,
    skippedRows,
    conflicts,
    untouchedProducts,
    untouchedVariants,
    categories: [...categoryCounts.entries()]
      .map(([category, count]) => ({ category, count }))
      .sort((a, b) => b.count - a.count || String(a.category).localeCompare(String(b.category), 'bg')),
    unitTypes: distinctCounts(rows.map((row) => row.unitType)),
    sourceLabels: distinctCounts(rows.map((row) => row.sourceLabel)),
    stats: {
      csvRows: rows.length,
      productsInCsv: groups.size,
      productsToInsert: productsToInsert.length,
      variantsToInsert: variantsToInsert.length,
      matchedProducts: matchedProducts.length,
      matchedVariants: matchedVariants.length,
      duplicatesSkipped: duplicates.length,
      skippedRows: skippedRows.length,
      conflicts: conflicts.length,
      untouchedProducts: untouchedProducts.length,
      untouchedVariants: untouchedVariants.length,
    },
  };
}

module.exports = {
  collationKey,
  productKey,
  categoryKey,
  variantKey,
  buildImportPlan,
};
