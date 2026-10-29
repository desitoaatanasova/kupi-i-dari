'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  HEADERS,
  normalizeText,
  parseCatalogCsv,
  decimalKey,
} = require('../src/lib/catalog-csv');
const { buildImportPlan } = require('../src/lib/catalog-import-plan');

function csvField(value) {
  const text = String(value);
  if (/[",\r\n]/.test(text)) {
    return `"${text.replace(/"/g, '""')}"`;
  }
  return text;
}

function sampleRow(overrides = {}) {
  return {
    category: 'Основни храни',
    product_name: 'Брашно',
    variant_label: '1 кг',
    unit_value: '1',
    unit_type: 'kg',
    source_label: 'Брашно - 1 кг',
    ...overrides,
  };
}

function makeCsv(rows, options = {}) {
  const { bom = true, eol = '\r\n' } = options;
  const lines = [
    HEADERS.join(','),
    ...rows.map((row) => HEADERS.map((header) => csvField(row[header] ?? '')).join(',')),
  ];
  return `${bom ? '\uFEFF' : ''}${lines.join(eol)}${eol}`;
}

function parseOne(row) {
  return parseCatalogCsv(makeCsv([sampleRow(row)]));
}

function assertError(result, code) {
  assert.equal(result.ok, false);
  assert.ok(
    result.errors.some((error) => error.code === code),
    `expected ${code}, got ${result.errors.map((error) => error.code).join(', ')}`
  );
}

test('requires the exact six headers in order', () => {
  const result = parseCatalogCsv(
    'category,product_name,variant_label,unit_value,unit_type\r\n' +
      'Основни храни,Брашно,1 кг,1,kg\r\n'
  );
  assertError(result, 'INVALID_HEADER');

  const reordered = parseCatalogCsv(
    'product_name,category,variant_label,unit_value,unit_type,source_label\r\n'
  );
  assertError(reordered, 'INVALID_HEADER');
});

test('accepts a UTF-8 BOM and CRLF or LF line endings', () => {
  for (const eol of ['\r\n', '\n']) {
    const result = parseCatalogCsv(makeCsv([sampleRow()], { eol }));
    assert.equal(result.ok, true);
    assert.equal(result.recordCount, 1);
    assert.equal(result.rows[0].productName, 'Брашно');
  }
});

test('supports quoted commas, escaped quotes and Bulgarian text', () => {
  const result = parseOne({
    product_name: 'Продукт "специален"',
    variant_label: '1,5 кг',
    source_label: 'Продукт, "специален" - 1,5 кг',
  });

  assert.equal(result.ok, true);
  assert.equal(result.rows[0].productName, 'Продукт "специален"');
  assert.equal(result.rows[0].variantLabel, '1,5 кг');
  assert.equal(result.rows[0].sourceLabel, 'Продукт, "специален" - 1,5 кг');
});

test('normalises names and labels with trim and whitespace collapse', () => {
  const result = parseOne({
    category: '  Основни   храни  ',
    product_name: '  Брашно   пшенично  ',
    variant_label: '  1   кг  ',
    unit_type: '  kg  ',
  });

  assert.equal(result.ok, true);
  const row = result.rows[0];
  assert.equal(row.category, 'Основни храни');
  assert.equal(row.productName, 'Брашно пшенично');
  assert.equal(row.variantLabel, '1 кг');
  assert.equal(row.unitType, 'kg');
  assert.equal(normalizeText('  a\t b  '), 'a b');
});

test('maps a blank category to null', () => {
  const result = parseOne({ category: '' });
  assert.equal(result.ok, true);
  assert.equal(result.rows[0].category, null);
});

test('rejects missing required fields and wrong column counts', () => {
  assertError(parseOne({ product_name: '' }), 'PRODUCT_NAME_REQUIRED');
  assertError(parseOne({ product_name: '   ' }), 'PRODUCT_NAME_REQUIRED');
  assertError(parseOne({ variant_label: '' }), 'VARIANT_LABEL_REQUIRED');
  assertError(
    parseCatalogCsv(
      'category,product_name,variant_label,unit_value,unit_type,source_label\r\n' +
        'Основни храни,Брашно,1 кг,1,kg\r\n'
    ),
    'COLUMN_COUNT'
  );
});

test('enforces the schema length limits', () => {
  assertError(parseOne({ category: 'К'.repeat(81) }), 'CATEGORY_TOO_LONG');
  assertError(parseOne({ product_name: 'П'.repeat(121) }), 'PRODUCT_NAME_TOO_LONG');
  assertError(parseOne({ variant_label: 'В'.repeat(41) }), 'VARIANT_LABEL_TOO_LONG');
});

test('parses nullable decimals with three-place precision and range checks', () => {
  const cases = [
    ['', null],
    ['0', 0],
    ['0.5', 0.5],
    ['1', 1],
    ['1.234', 1.234],
  ];
  for (const [input, expected] of cases) {
    const result = parseOne({ unit_value: input });
    assert.equal(result.ok, true, `unit_value=${input}`);
    assert.equal(result.rows[0].unitValue, expected);
  }

  assertError(parseOne({ unit_value: '1,5' }), 'UNIT_VALUE_FORMAT');
  assertError(parseOne({ unit_value: '1.2345' }), 'UNIT_VALUE_PRECISION');
  assertError(parseOne({ unit_value: '10000000' }), 'UNIT_VALUE_RANGE');
  assertError(parseOne({ unit_value: '-1' }), 'UNIT_VALUE_FORMAT');
  assertError(parseOne({ unit_value: '1e3' }), 'UNIT_VALUE_FORMAT');

  assert.equal(decimalKey('1.000'), decimalKey(1));
  assert.equal(decimalKey('0.500'), decimalKey(0.5));
  assert.equal(decimalKey(null), null);
  assert.notEqual(decimalKey(null), decimalKey(0));
});

test('rejects replacement characters, NUL characters and invalid UTF-8', () => {
  assertError(parseOne({ product_name: 'Брашно\uFFFD' }), 'CORRUPTED_TEXT');
  assertError(parseOne({ product_name: 'Брашно\u0000' }), 'CORRUPTED_TEXT');

  const invalidUtf8 = Buffer.from([
    0x63, 0x61, 0x74, 0x65, 0x67, 0x6f, 0x72, 0x79, 0x0a, 0xff,
  ]);
  assertError(parseCatalogCsv(invalidUtf8), 'INVALID_ENCODING');
});

test('reports blank lines but keeps valid records', () => {
  const text = `${makeCsv([sampleRow()]).trimEnd()}\r\n\r\n`;
  const result = parseCatalogCsv(text);
  assert.equal(result.ok, true);
  assert.equal(result.recordCount, 1);
  assert.ok(result.warnings.some((warning) => warning.code === 'EMPTY_LINE'));
});

test('groups multiple CSV rows under one product', () => {
  const result = parseCatalogCsv(
    makeCsv([
      sampleRow(),
      sampleRow({ variant_label: '0,5 кг', unit_value: '0.5', source_label: 'Брашно - 0.5 кг' }),
    ])
  );
  const plan = buildImportPlan(result.rows, {});

  assert.equal(plan.ok, true);
  assert.equal(plan.productsToInsert.length, 1);
  assert.equal(plan.productsToInsert[0].name, 'Брашно');
  assert.equal(plan.productsToInsert[0].variants.length, 2);
  assert.equal(plan.variantsToInsert.length, 2);
  assert.equal(plan.stats.productsInCsv, 1);
});

test('detects conflicting categories for one product without splitting it', () => {
  const result = parseCatalogCsv(
    makeCsv([
      sampleRow(),
      sampleRow({ category: 'Други', variant_label: '0,5 кг', unit_value: '0.5' }),
    ])
  );
  const plan = buildImportPlan(result.rows, {});

  assert.equal(plan.ok, false);
  assert.equal(plan.productsToInsert.length, 0);
  assert.equal(plan.conflicts.length, 1);
  assert.equal(plan.conflicts[0].code, 'CATEGORY_CONFLICT');
});

test('skips identical duplicate rows and conflicts on incompatible duplicates', () => {
  const identical = parseCatalogCsv(makeCsv([sampleRow(), sampleRow()]));
  const identicalPlan = buildImportPlan(identical.rows, {});
  assert.equal(identicalPlan.ok, true);
  assert.equal(identicalPlan.duplicates.length, 1);
  assert.equal(identicalPlan.variantsToInsert.length, 1);

  const incompatible = parseCatalogCsv(
    makeCsv([sampleRow({ unit_value: '1' }), sampleRow({ unit_value: '2' })])
  );
  const incompatiblePlan = buildImportPlan(incompatible.rows, {});
  assert.equal(incompatiblePlan.ok, false);
  assert.equal(incompatiblePlan.conflicts[0].code, 'DUPLICATE_VARIANT_CONFLICT');
});

test('matches existing products and variants case-insensitively', () => {
  const parsed = parseCatalogCsv(makeCsv([sampleRow()]));
  const plan = buildImportPlan(parsed.rows, {
    products: [
      { productId: 10, name: 'БРАШНО', category: 'Основни храни', isActive: true },
    ],
    variants: [
      {
        variantId: 20,
        productId: 10,
        unitLabel: '1 КГ',
        unitValue: '1.000',
        isActive: true,
      },
    ],
  });

  assert.equal(plan.ok, true);
  assert.equal(plan.productsToInsert.length, 0);
  assert.equal(plan.variantsToInsert.length, 0);
  assert.equal(plan.matchedProducts.length, 1);
  assert.equal(plan.matchedVariants.length, 1);
});

test('conflicts on a NULL existing category instead of filling it', () => {
  const parsed = parseCatalogCsv(makeCsv([sampleRow()]));
  const plan = buildImportPlan(parsed.rows, {
    products: [{ productId: 10, name: 'Брашно', category: null, isActive: true }],
    variants: [],
  });

  assert.equal(plan.ok, false);
  assert.equal(plan.conflicts[0].code, 'CATEGORY_MISSING');
});

test('conflicts on category and unit-value mismatches without proposing updates', () => {
  const parsed = parseCatalogCsv(makeCsv([sampleRow()]));

  const categoryPlan = buildImportPlan(parsed.rows, {
    products: [
      { productId: 10, name: 'Брашно', category: 'Други', isActive: true },
    ],
    variants: [],
  });
  assert.equal(categoryPlan.conflicts[0].code, 'CATEGORY_MISMATCH');

  const valuePlan = buildImportPlan(parsed.rows, {
    products: [
      { productId: 10, name: 'Брашно', category: 'Основни храни', isActive: true },
    ],
    variants: [
      { variantId: 20, productId: 10, unitLabel: '1 кг', unitValue: '2.000', isActive: true },
    ],
  });
  assert.equal(valuePlan.conflicts[0].code, 'UNIT_VALUE_MISMATCH');
  assert.equal(valuePlan.variantsToInsert.length, 0);
});

test('conflicts on archived products and variants without reactivating them', () => {
  const parsed = parseCatalogCsv(makeCsv([sampleRow()]));

  const archivedProduct = buildImportPlan(parsed.rows, {
    products: [
      { productId: 10, name: 'Брашно', category: 'Основни храни', isActive: false },
    ],
    variants: [],
  });
  assert.equal(archivedProduct.conflicts[0].code, 'ARCHIVED_PRODUCT');

  const archivedVariant = buildImportPlan(parsed.rows, {
    products: [
      { productId: 10, name: 'Брашно', category: 'Основни храни', isActive: true },
    ],
    variants: [
      { variantId: 20, productId: 10, unitLabel: '1 кг', unitValue: '1.000', isActive: false },
    ],
  });
  assert.equal(archivedVariant.conflicts[0].code, 'ARCHIVED_VARIANT');
});

test('reports untouched existing records and informational columns', () => {
  const parsed = parseCatalogCsv(makeCsv([sampleRow()]));
  const plan = buildImportPlan(parsed.rows, {
    products: [
      { productId: 10, name: 'Брашно', category: 'Основни храни', isActive: true },
      { productId: 11, name: 'Ориз', category: 'Основни храни', isActive: true },
    ],
    variants: [
      { variantId: 20, productId: 10, unitLabel: '1 кг', unitValue: '1.000', isActive: true },
      { variantId: 21, productId: 10, unitLabel: '2 кг', unitValue: '2.000', isActive: true },
      { variantId: 22, productId: 11, unitLabel: '1 кг', unitValue: '1.000', isActive: true },
    ],
  });

  assert.equal(plan.unitTypes.length, 1);
  assert.equal(plan.unitTypes[0].value, 'kg');
  assert.equal(plan.unitTypes[0].count, 1);
  assert.equal(plan.sourceLabels[0].value, 'Брашно - 1 кг');
  assert.equal(plan.untouchedProducts.length, 1);
  assert.equal(plan.untouchedProducts[0].name, 'Ориз');
  assert.deepEqual(
    plan.untouchedVariants.map((variant) => variant.variantId).sort((a, b) => a - b),
    [21, 22]
  );
  assert.equal(
    plan.variantsToInsert.every((variant) => !('unitType' in variant)),
    true
  );
});
