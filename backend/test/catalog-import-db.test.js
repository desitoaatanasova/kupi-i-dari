'use strict';

require('./helpers/env');

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { ensureMigrated, getTestConnection, config } = require('./helpers/db');
const auth = require('./helpers/auth');
const {
  runImport,
  applyPlan,
  assertSafeTarget,
} = require('../scripts/import-product-catalog');

const PREFIX = 'CatalogImportTest-';
const HEADER_LINE = 'category,product_name,variant_label,unit_value,unit_type,source_label';
const tempDirs = [];

let connection;

function csvField(value) {
  const text = String(value);
  if (/[",\r\n]/.test(text)) {
    return `"${text.replace(/"/g, '""')}"`;
  }
  return text;
}

function row(overrides = {}) {
  return {
    category: 'Основни храни',
    product_name: `${PREFIX}Брашно`,
    variant_label: '1 кг',
    unit_value: '1',
    unit_type: 'kg',
    source_label: 'Брашно - 1 кг',
    ...overrides,
  };
}

function writeCsv(rows) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'catalog-import-'));
  tempDirs.push(dir);
  const file = path.join(dir, 'catalog.csv');
  const lines = [
    HEADER_LINE,
    ...rows.map((entry) =>
      [
        entry.category,
        entry.product_name,
        entry.variant_label,
        entry.unit_value,
        entry.unit_type,
        entry.source_label,
      ]
        .map(csvField)
        .join(',')
    ),
  ];
  fs.writeFileSync(file, `\uFEFF${lines.join('\r\n')}\r\n`, 'utf8');
  return file;
}

function removeTempDirs() {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function cleanupPrefix() {
  const [products] = await connection.query(
    'SELECT product_id FROM products WHERE name LIKE ?',
    [`${PREFIX}%`]
  );
  const productIds = products.map((product) => product.product_id);

  let variantIds = [];
  if (productIds.length > 0) {
    const [variants] = await connection.query(
      'SELECT variant_id FROM product_variants WHERE product_id IN (?)',
      [productIds]
    );
    variantIds = variants.map((variant) => variant.variant_id);
  }

  const [locations] = await connection.query(
    'SELECT location_id FROM locations WHERE name LIKE ?',
    [`${PREFIX}%`]
  );
  const locationIds = locations.map((location) => location.location_id);

  if (variantIds.length > 0) {
    await connection.query('DELETE FROM distributions WHERE variant_id IN (?)', [variantIds]);
    await connection.query('DELETE FROM collected_quantities WHERE variant_id IN (?)', [variantIds]);
  }
  if (locationIds.length > 0) {
    await connection.query('DELETE FROM distributions WHERE location_id IN (?)', [locationIds]);
  }
  if (productIds.length > 0) {
    await connection.query('DELETE FROM product_variants WHERE product_id IN (?)', [productIds]);
    await connection.query('DELETE FROM products WHERE product_id IN (?)', [productIds]);
  }
  if (locationIds.length > 0) {
    await connection.query('DELETE FROM locations WHERE location_id IN (?)', [locationIds]);
  }
}

async function importFile(file, apply = true) {
  return runImport({
    filePath: file,
    target: config.db.name,
    apply,
  });
}

before(async () => {
  assert.match(config.db.name, /_test$/i, 'integration tests must use DB_NAME_TEST');
  await ensureMigrated();
  connection = await getTestConnection();
  await cleanupPrefix();
});

after(async () => {
  await cleanupPrefix();
  await connection.end();
  removeTempDirs();
  await auth.pool.end();
});

beforeEach(async () => {
  await cleanupPrefix();
});

test('imports missing products and variants in one transaction', async () => {
  const file = writeCsv([
    row({ variant_label: '0,5 кг', unit_value: '0.5' }),
    row({ variant_label: '1 кг', unit_value: '1' }),
  ]);

  const result = await importFile(file, true);

  assert.equal(result.ok, true);
  assert.equal(result.report.mode, 'apply');
  assert.equal(result.report.insertedProducts.length, 1);
  assert.equal(result.report.insertedVariants.length, 2);

  const [products] = await connection.query(
    'SELECT product_id, name, category, is_active FROM products WHERE name = ?',
    [`${PREFIX}Брашно`]
  );
  assert.equal(products.length, 1);
  assert.equal(products[0].category, 'Основни храни');
  assert.equal(products[0].is_active, 1);

  const [variants] = await connection.query(
    'SELECT unit_label, unit_value FROM product_variants WHERE product_id = ? ORDER BY unit_label',
    [products[0].product_id]
  );
  assert.deepEqual(
    variants
      .map((variant) => [variant.unit_label, Number(variant.unit_value)])
      .sort((a, b) => a[0].localeCompare(b[0], 'bg')),
    [
      ['0,5 кг', 0.5],
      ['1 кг', 1],
    ].sort((a, b) => a[0].localeCompare(b[0], 'bg'))
  );
});

test('rerunning an unchanged import is idempotent', async () => {
  const file = writeCsv([
    row({ variant_label: '0,5 кг', unit_value: '0.5' }),
    row({ variant_label: '1 кг', unit_value: '1' }),
  ]);

  const first = await importFile(file, true);
  assert.equal(first.ok, true);
  assert.equal(first.report.insertedProducts.length, 1);
  assert.equal(first.report.insertedVariants.length, 2);

  const second = await importFile(file, true);
  assert.equal(second.ok, true);
  assert.equal(second.report.insertedProducts.length, 0);
  assert.equal(second.report.insertedVariants.length, 0);
  assert.equal(second.report.matchedProducts.length, 1);
  assert.equal(second.report.matchedVariants.length, 2);

  const [[productCount]] = await connection.query(
    'SELECT COUNT(*) AS n FROM products WHERE name = ?',
    [`${PREFIX}Брашно`]
  );
  assert.equal(productCount.n, 1);
});

test('dry-run plans without writing', async () => {
  const file = writeCsv([row()]);

  const result = await importFile(file, false);

  assert.equal(result.ok, true);
  assert.equal(result.report.mode, 'dry-run');
  assert.equal(result.report.insertedProducts.length, 0);

  const [[productCount]] = await connection.query(
    'SELECT COUNT(*) AS n FROM products WHERE name = ?',
    [`${PREFIX}Брашно`]
  );
  assert.equal(productCount.n, 0);
});

test('matches an existing product and variant, then adds only the missing variant', async () => {
  const productId = await auth.createProduct({
    name: `${PREFIX}Брашно`,
    category: 'Основни храни',
  });
  const variantId = await auth.createVariant({
    productId,
    unitLabel: '1 кг',
    unitValue: 1,
  });

  const file = writeCsv([
    row({ variant_label: '1 кг', unit_value: '1' }),
    row({ variant_label: '2 кг', unit_value: '2' }),
  ]);
  const result = await importFile(file, true);

  assert.equal(result.ok, true);
  assert.equal(result.report.insertedProducts.length, 0);
  assert.equal(result.report.insertedVariants.length, 1);
  assert.equal(result.report.matchedProducts[0].productId, productId);
  assert.equal(result.report.matchedVariants[0].variantId, variantId);

  const [variants] = await connection.query(
    'SELECT variant_id, unit_label FROM product_variants WHERE product_id = ? ORDER BY unit_label',
    [productId]
  );
  assert.equal(variants.length, 2);
  assert.ok(variants.some((variant) => variant.variant_id === variantId));
});

test('category conflicts abort the whole apply without writing', async () => {
  const productId = await auth.createProduct({
    name: `${PREFIX}Брашно`,
    category: 'Други',
  });

  const file = writeCsv([
    row(),
    row({
      product_name: `${PREFIX}Нов продукт`,
      variant_label: '1 бр.',
      unit_type: 'бр.',
      source_label: 'Нов продукт',
    }),
  ]);
  const result = await importFile(file, true);

  assert.equal(result.ok, false);
  assert.equal(result.report.conflicts[0].code, 'CATEGORY_MISMATCH');
  assert.equal(result.report.insertedProducts.length, 0);

  const [products] = await connection.query(
    'SELECT product_id, category FROM products WHERE product_id = ?',
    [productId]
  );
  assert.equal(products[0].category, 'Други');

  const [[newProductCount]] = await connection.query(
    'SELECT COUNT(*) AS n FROM products WHERE name = ?',
    [`${PREFIX}Нов продукт`]
  );
  assert.equal(newProductCount.n, 0);
});

test('archived products are conflicts and are never reactivated', async () => {
  const productId = await auth.createProduct({
    name: `${PREFIX}Брашно`,
    category: 'Основни храни',
    isActive: false,
  });

  const result = await importFile(writeCsv([row()]), true);

  assert.equal(result.ok, false);
  assert.equal(result.report.conflicts[0].code, 'ARCHIVED_PRODUCT');

  const [products] = await connection.query(
    'SELECT is_active FROM products WHERE product_id = ?',
    [productId]
  );
  assert.equal(products[0].is_active, 0);
});

test('archived variants are conflicts and are never reactivated', async () => {
  const productId = await auth.createProduct({
    name: `${PREFIX}Брашно`,
    category: 'Основни храни',
  });
  const variantId = await auth.createVariant({
    productId,
    unitLabel: '1 кг',
    unitValue: 1,
    isActive: false,
  });

  const result = await importFile(writeCsv([row()]), true);

  assert.equal(result.ok, false);
  assert.equal(result.report.conflicts[0].code, 'ARCHIVED_VARIANT');

  const [variants] = await connection.query(
    'SELECT variant_id, is_active FROM product_variants WHERE product_id = ?',
    [productId]
  );
  assert.equal(variants.length, 1);
  assert.equal(variants[0].variant_id, variantId);
  assert.equal(variants[0].is_active, 0);
});

test('unit-value mismatches are conflicts without updates', async () => {
  const productId = await auth.createProduct({
    name: `${PREFIX}Брашно`,
    category: 'Основни храни',
  });
  const variantId = await auth.createVariant({
    productId,
    unitLabel: '1 кг',
    unitValue: 1,
  });

  const result = await importFile(writeCsv([row({ unit_value: '2' })]), true);

  assert.equal(result.ok, false);
  assert.equal(result.report.conflicts[0].code, 'UNIT_VALUE_MISMATCH');

  const [variants] = await connection.query(
    'SELECT variant_id, unit_value FROM product_variants WHERE product_id = ?',
    [productId]
  );
  assert.equal(variants.length, 1);
  assert.equal(variants[0].variant_id, variantId);
  assert.equal(Number(variants[0].unit_value), 1);
});

test('identical duplicate CSV rows are reported and skipped', async () => {
  const file = writeCsv([row(), row()]);

  const result = await importFile(file, true);

  assert.equal(result.ok, true);
  assert.equal(result.report.duplicatesSkipped.length, 1);
  assert.equal(result.report.insertedProducts.length, 1);
  assert.equal(result.report.insertedVariants.length, 1);
});

test('incompatible duplicate CSV rows abort the apply without writing', async () => {
  const file = writeCsv([
    row({ unit_value: '1' }),
    row({ unit_value: '2' }),
    row({
      product_name: `${PREFIX}Нов продукт`,
      variant_label: '1 бр.',
      unit_type: 'бр.',
      source_label: 'Нов продукт',
    }),
  ]);

  const result = await importFile(file, true);

  assert.equal(result.ok, false);
  assert.ok(
    result.report.conflicts.some((conflict) => conflict.code === 'DUPLICATE_VARIANT_CONFLICT')
  );

  const [[productCount]] = await connection.query(
    'SELECT COUNT(*) AS n FROM products WHERE name LIKE ?',
    [`${PREFIX}%`]
  );
  assert.equal(productCount.n, 0);
});

test('preserves existing variant ids, quantities and distribution history', async () => {
  const productId = await auth.createProduct({
    name: `${PREFIX}Брашно`,
    category: 'Основни храни',
  });
  const variantId = await auth.createVariant({
    productId,
    unitLabel: '1 кг',
    unitValue: 1,
  });
  const locationId = await auth.createLocation({ name: `${PREFIX}Пункт` });
  const quantityId = await auth.createCollectedQuantity({
    locationId,
    variantId,
    quantity: 7,
  });
  const distributionId = await auth.createDistribution({
    locationId,
    variantId,
    quantity: 2,
  });

  const file = writeCsv([
    row({ variant_label: '1 кг', unit_value: '1' }),
    row({ variant_label: '2 кг', unit_value: '2' }),
  ]);
  const result = await importFile(file, true);

  assert.equal(result.ok, true);
  assert.equal(result.report.insertedProducts.length, 0);
  assert.equal(result.report.insertedVariants.length, 1);

  const [variants] = await connection.query(
    'SELECT variant_id FROM product_variants WHERE product_id = ? ORDER BY variant_id',
    [productId]
  );
  assert.ok(variants.some((variant) => variant.variant_id === variantId));

  const [quantities] = await connection.query(
    'SELECT collected_quantity_id, location_id, variant_id, quantity FROM collected_quantities WHERE collected_quantity_id = ?',
    [quantityId]
  );
  assert.deepEqual(quantities, [
    {
      collected_quantity_id: quantityId,
      location_id: locationId,
      variant_id: variantId,
      quantity: 7,
    },
  ]);

  const [distributions] = await connection.query(
    'SELECT distribution_id, location_id, variant_id, quantity FROM distributions WHERE distribution_id = ?',
    [distributionId]
  );
  assert.deepEqual(distributions, [
    {
      distribution_id: distributionId,
      location_id: locationId,
      variant_id: variantId,
      quantity: 2,
    },
  ]);
});

test('a unique-constraint failure rolls back the whole transaction', async () => {
  const rollbackConnection = await getTestConnection();
  try {
    await rollbackConnection.beginTransaction();
    const plan = {
      matchedProducts: [],
      productsToInsert: [
        { key: 'a', name: `${PREFIX}Rollback`, category: null, lines: [2] },
        { key: 'b', name: `${PREFIX}Rollback`, category: null, lines: [3] },
      ],
      variantsToInsert: [],
    };

    await assert.rejects(
      () => applyPlan(rollbackConnection, plan),
      (error) => error.code === 'ER_DUP_ENTRY'
    );
    await rollbackConnection.rollback();

    const [products] = await rollbackConnection.query(
      'SELECT product_id FROM products WHERE name = ?',
      [`${PREFIX}Rollback`]
    );
    assert.equal(products.length, 0);
  } finally {
    await rollbackConnection.end();
  }
});

test('the development database target is refused before connecting', async () => {
  assert.throws(() => assertSafeTarget('kupi_i_dari'), /Refusing to connect/);
  await assert.rejects(
    () => runImport({ filePath: writeCsv([row()]), target: 'kupi_i_dari', apply: false }),
    (error) => error.code === 'TARGET_FORBIDDEN'
  );
});
