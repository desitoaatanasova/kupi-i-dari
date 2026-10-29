#!/usr/bin/env node
'use strict';

require('dotenv').config();

const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');

const config = require('../src/config');
const { checksum } = require('../src/lib/migrator');
const { parseCatalogCsv, HEADERS } = require('../src/lib/catalog-csv');
const { buildImportPlan } = require('../src/lib/catalog-import-plan');

const DEV_DATABASE = 'kupi_i_dari';
const DEFAULT_FILE = path.resolve(
  __dirname,
  '..',
  '..',
  'docs',
  'data',
  'product_catalog_weekend3_edited.csv'
);

const REQUIRED_TABLES = [
  'schema_migrations',
  'users',
  'locations',
  'responsible_locations',
  'products',
  'product_variants',
  'shifts',
  'shift_locations',
  'shift_registrations',
  'collected_quantities',
  'distributions',
];

const REQUIRED_COLUMNS = {
  schema_migrations: ['filename', 'checksum'],
  products: ['product_id', 'name', 'category', 'is_active'],
  product_variants: ['variant_id', 'product_id', 'unit_label', 'unit_value', 'is_active'],
};

class ImportError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ImportError';
    this.code = code;
  }
}

function usage() {
  return [
    'Usage: node scripts/import-product-catalog.js --target <database> [options]',
    '',
    'Options:',
    '  --file <path>      CSV path (default: docs/data/product_catalog_weekend3_edited.csv)',
    '  --target <name>    Explicit target database (required; kupi_i_dari is refused)',
    '  --apply            Permit writes. Without this flag the run is a dry-run.',
    '  --json             Print a machine-readable report.',
    '  --help             Show this help.',
  ].join('\n');
}

function parseArgs(argv) {
  const args = {
    file: DEFAULT_FILE,
    target: null,
    apply: false,
    json: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') {
      args.help = true;
    } else if (arg === '--apply') {
      args.apply = true;
    } else if (arg === '--json') {
      args.json = true;
    } else if (arg === '--file' || arg === '--target') {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith('--')) {
        throw new ImportError('USAGE', `${arg} requires a value.`);
      }
      args[arg.slice(2)] = value;
      index += 1;
    } else if (arg.startsWith('--file=')) {
      args.file = arg.slice('--file='.length);
    } else if (arg.startsWith('--target=')) {
      args.target = arg.slice('--target='.length);
    } else {
      throw new ImportError('USAGE', `Unknown argument: ${arg}`);
    }
  }

  return args;
}

function assertSafeTarget(target) {
  if (typeof target !== 'string' || !/^[A-Za-z0-9_]+$/.test(target)) {
    throw new ImportError('TARGET_INVALID', 'Target must be a simple database name.');
  }
  if (target.toLowerCase() === DEV_DATABASE) {
    throw new ImportError(
      'TARGET_FORBIDDEN',
      `Refusing to connect to the development database "${DEV_DATABASE}".`
    );
  }
}

function connectionOptions(database) {
  return {
    host: config.db.host,
    port: config.db.port,
    user: config.db.user,
    password: config.db.password,
    database,
    charset: config.db.charset,
    multipleStatements: false,
  };
}

async function openConnection(target) {
  assertSafeTarget(target);
  return mysql.createConnection(connectionOptions(target));
}

function expectedMigrations() {
  if (!fs.existsSync(config.migrationsDir)) {
    throw new ImportError(
      'MIGRATIONS_MISSING',
      `Migrations directory not found: ${config.migrationsDir}`
    );
  }

  return fs
    .readdirSync(config.migrationsDir)
    .filter((name) => name.toLowerCase().endsWith('.sql'))
    .sort((a, b) => a.localeCompare(b, 'en'))
    .map((filename) => ({
      filename,
      checksum: checksum(fs.readFileSync(path.join(config.migrationsDir, filename))),
    }));
}

async function preflight(connection, target) {
  const [databaseRows] = await connection.query('SELECT DATABASE() AS name');
  const database = databaseRows[0] && databaseRows[0].name;
  if (database !== target) {
    throw new ImportError(
      'TARGET_MISMATCH',
      `Connected database is "${database}", expected "${target}".`
    );
  }

  const [tableRows] = await connection.query(
    `SELECT TABLE_NAME AS name
       FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE()`
  );
  const tables = new Set(tableRows.map((row) => row.name));
  const missingTables = REQUIRED_TABLES.filter((table) => !tables.has(table));
  if (missingTables.length > 0) {
    throw new ImportError(
      'SCHEMA_INCOMPATIBLE',
      `Target database is missing tables: ${missingTables.join(', ')}.`
    );
  }

  const [columnRows] = await connection.query(
    `SELECT TABLE_NAME AS tableName, COLUMN_NAME AS columnName
       FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()`
  );
  const columns = new Map();
  for (const row of columnRows) {
    if (!columns.has(row.tableName)) columns.set(row.tableName, new Set());
    columns.get(row.tableName).add(row.columnName);
  }

  const missingColumns = [];
  for (const [table, names] of Object.entries(REQUIRED_COLUMNS)) {
    for (const name of names) {
      if (!columns.has(table) || !columns.get(table).has(name)) {
        missingColumns.push(`${table}.${name}`);
      }
    }
  }
  if (missingColumns.length > 0) {
    throw new ImportError(
      'SCHEMA_INCOMPATIBLE',
      `Target database is missing columns: ${missingColumns.join(', ')}.`
    );
  }

  const migrations = expectedMigrations();
  const [appliedRows] = await connection.query(
    'SELECT filename, checksum FROM schema_migrations'
  );
  const applied = new Map(appliedRows.map((row) => [row.filename, row.checksum]));
  const expectedNames = new Set(migrations.map((migration) => migration.filename));

  const unexpected = appliedRows
    .map((row) => row.filename)
    .filter((filename) => !expectedNames.has(filename));
  if (unexpected.length > 0) {
    throw new ImportError(
      'MIGRATION_MISMATCH',
      `Target schema has unknown recorded migrations: ${unexpected.join(', ')}.`
    );
  }

  for (const migration of migrations) {
    if (!applied.has(migration.filename)) {
      throw new ImportError(
        'MIGRATION_MISMATCH',
        `Target schema is missing migration "${migration.filename}".`
      );
    }
    if (applied.get(migration.filename) !== migration.checksum) {
      throw new ImportError(
        'MIGRATION_MISMATCH',
        `Checksum mismatch for "${migration.filename}".`
      );
    }
  }

  return {
    database,
    migrations: migrations.map((migration) => migration.filename),
  };
}

function toCanonicalProduct(row) {
  return {
    productId: row.product_id,
    name: row.name,
    category: row.category,
    isActive: Boolean(row.is_active),
  };
}

function toCanonicalVariant(row) {
  return {
    variantId: row.variant_id,
    productId: row.product_id,
    unitLabel: row.unit_label,
    unitValue: row.unit_value,
    isActive: Boolean(row.is_active),
  };
}

async function loadSnapshot(connection, lock) {
  const lockClause = lock ? ' FOR UPDATE' : '';

  const [productRows] = await connection.query(
    `SELECT product_id, name, category, is_active
       FROM products
      ORDER BY product_id${lockClause}`
  );
  const [variantRows] = await connection.query(
    `SELECT variant_id, product_id, unit_label, unit_value, is_active
       FROM product_variants
      ORDER BY variant_id${lockClause}`
  );

  return {
    products: productRows.map(toCanonicalProduct),
    variants: variantRows.map(toCanonicalVariant),
  };
}

async function applyPlan(connection, plan) {
  const productIdsByKey = new Map();
  for (const product of plan.matchedProducts) {
    productIdsByKey.set(product.productKey, product.productId);
  }

  const inserted = { products: [], variants: [] };

  for (const product of plan.productsToInsert) {
    const [result] = await connection.query(
      'INSERT INTO products (name, category, is_active) VALUES (?, ?, 1)',
      [product.name, product.category]
    );
    productIdsByKey.set(product.key, result.insertId);
    inserted.products.push({
      productId: result.insertId,
      productKey: product.key,
      name: product.name,
      category: product.category,
    });
  }

  for (const variant of plan.variantsToInsert) {
    const productId = variant.productId ?? productIdsByKey.get(variant.productKey);
    if (!productId) {
      throw new ImportError(
        'IMPORT_PLAN_INVALID',
        `No product id resolved for variant under "${variant.productName}".`
      );
    }

    const [result] = await connection.query(
      `INSERT INTO product_variants (product_id, unit_label, unit_value, is_active)
       VALUES (?, ?, ?, 1)`,
      [productId, variant.unitLabel, variant.unitValue]
    );
    inserted.variants.push({
      variantId: result.insertId,
      productId,
      productKey: variant.productKey,
      unitLabel: variant.unitLabel,
      unitValue: variant.unitValue,
    });
  }

  return inserted;
}

function exitCodeFor(report) {
  return report.ok ? 0 : 1;
}

function buildReport({ mode, target, filePath, parsed, plan, preflightResult, inserted }) {
  return {
    ok: parsed.ok && plan.ok,
    mode,
    target,
    sourceFile: filePath,
    parsedRowCount: parsed.recordCount,
    sourceRecordCount: parsed.sourceRecordCount,
    header: parsed.header || HEADERS,
    categories: plan.categories,
    unitTypes: plan.unitTypes,
    sourceLabels: plan.sourceLabels,
    productsPlanned: plan.productsToInsert.map((product) => ({
      productKey: product.key,
      name: product.name,
      category: product.category,
      lines: product.lines,
    })),
    variantsPlanned: plan.variantsToInsert.map((variant) => ({
      productKey: variant.productKey,
      productName: variant.productName,
      unitLabel: variant.unitLabel,
      unitValue: variant.unitValue,
      lines: variant.lines,
    })),
    matchedProducts: plan.matchedProducts,
    matchedVariants: plan.matchedVariants,
    duplicatesSkipped: plan.duplicates,
    conflicts: plan.conflicts,
    skippedRows: plan.skippedRows,
    untouchedProducts: plan.untouchedProducts,
    untouchedVariants: plan.untouchedVariants,
    insertedProducts: inserted ? inserted.products : [],
    insertedVariants: inserted ? inserted.variants : [],
    warnings: parsed.warnings,
    errors: parsed.errors,
    preflight: preflightResult
      ? { database: preflightResult.database, migrations: preflightResult.migrations.length }
      : null,
    stats: plan.stats,
  };
}

function formatValue(value) {
  if (value === null || value === undefined) return '(blank)';
  return String(value);
}

function printReport(report, json) {
  if (json) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  console.log(`[catalog-import] mode: ${report.mode}`);
  console.log(`[catalog-import] target: ${report.target}`);
  console.log(`[catalog-import] source: ${report.sourceFile}`);
  console.log(`[catalog-import] parsed rows: ${report.parsedRowCount}`);
  console.log('[catalog-import] categories:');
  for (const category of report.categories) {
    console.log(`  ${category.count} x ${formatValue(category.category)}`);
  }
  console.log(
    '[catalog-import] unit types: ' +
      (report.unitTypes.length === 0
        ? '(none)'
        : report.unitTypes.map((entry) => `${formatValue(entry.value)} (${entry.count})`).join(', '))
  );
  console.log(
    '[catalog-import] source labels: ' +
      (report.sourceLabels.length === 0
        ? '(none)'
        : report.sourceLabels.map((entry) => entry.value).join(' | '))
  );
  console.log(`[catalog-import] products planned: ${report.productsPlanned.length}`);
  console.log(`[catalog-import] variants planned: ${report.variantsPlanned.length}`);
  console.log(`[catalog-import] matched products: ${report.matchedProducts.length}`);
  console.log(`[catalog-import] matched variants: ${report.matchedVariants.length}`);
  console.log(`[catalog-import] duplicate rows skipped: ${report.duplicatesSkipped.length}`);
  console.log(`[catalog-import] conflicts: ${report.conflicts.length}`);
  console.log(`[catalog-import] untouched products: ${report.untouchedProducts.length}`);
  console.log(`[catalog-import] untouched variants: ${report.untouchedVariants.length}`);

  for (const error of report.errors) {
    console.log(`[catalog-import] ERROR line ${error.line}: ${error.code}: ${error.message}`);
  }
  for (const conflict of report.conflicts) {
    const line = conflict.line || (conflict.lines || []).join(',');
    console.log(
      `[catalog-import] CONFLICT line ${line || '?'}: ${conflict.code}: ` +
        `${conflict.message || ''}`
    );
  }

  if (report.mode === 'apply') {
    console.log(`[catalog-import] inserted products: ${report.insertedProducts.length}`);
    console.log(`[catalog-import] inserted variants: ${report.insertedVariants.length}`);
  } else {
    console.log('[catalog-import] dry-run: no database writes performed');
  }
}

async function runImport({ filePath, target, apply = false }) {
  assertSafeTarget(target);

  const absoluteFile = path.resolve(filePath);
  let buffer;
  try {
    buffer = fs.readFileSync(absoluteFile);
  } catch (error) {
    throw new ImportError('CSV_NOT_FOUND', `Cannot read CSV file: ${absoluteFile}`);
  }

  const parsed = parseCatalogCsv(buffer);
  if (!parsed.ok) {
    const plan = buildImportPlan([], {});
    return {
      ok: false,
      report: buildReport({
        mode: apply ? 'apply' : 'dry-run',
        target,
        filePath: absoluteFile,
        parsed,
        plan,
        preflightResult: null,
        inserted: null,
      }),
    };
  }

  const connection = await openConnection(target);
  let transactionOpen = false;
  let report;

  try {
    const preflightResult = await preflight(connection, target);

    if (apply) {
      await connection.beginTransaction();
      transactionOpen = true;
    } else {
      await connection.query('START TRANSACTION READ ONLY');
      transactionOpen = true;
    }

    const snapshot = await loadSnapshot(connection, apply);
    const plan = buildImportPlan(parsed.rows, snapshot);

    if (!plan.ok) {
      await connection.query('ROLLBACK');
      transactionOpen = false;
      return {
        ok: false,
        report: buildReport({
          mode: apply ? 'apply' : 'dry-run',
          target,
          filePath: absoluteFile,
          parsed,
          plan,
          preflightResult,
          inserted: null,
        }),
      };
    }

    let inserted = null;
    if (apply) {
      try {
        inserted = await applyPlan(connection, plan);
      } catch (error) {
        if (error && error.code === 'ER_DUP_ENTRY') {
          throw new ImportError(
            'CONCURRENT_CHANGE',
            'A unique-constraint race was detected during apply. ' +
              'Nothing was committed; rerun the dry-run and apply again.'
          );
        }
        throw error;
      }
    }

    await connection.query(apply ? 'COMMIT' : 'ROLLBACK');
    transactionOpen = false;

    report = buildReport({
      mode: apply ? 'apply' : 'dry-run',
      target,
      filePath: absoluteFile,
      parsed,
      plan,
      preflightResult,
      inserted,
    });

    return { ok: report.ok, report };
  } catch (error) {
    if (transactionOpen) {
      try {
        await connection.query('ROLLBACK');
      } catch (rollbackError) {
        // Surface the original failure.
      }
    }
    throw error;
  } finally {
    await connection.end();
  }
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`[catalog-import] ${error.message}`);
    console.error(usage());
    process.exitCode = 2;
    return;
  }

  if (args.help) {
    console.log(usage());
    return;
  }

  if (!args.target) {
    console.error('[catalog-import] --target is required.');
    console.error(usage());
    process.exitCode = 2;
    return;
  }

  try {
    const result = await runImport({
      filePath: args.file,
      target: args.target,
      apply: args.apply,
    });
    printReport(result.report, args.json);
    process.exitCode = exitCodeFor(result.report);
  } catch (error) {
    if (args.json) {
      console.log(
        JSON.stringify(
          {
            ok: false,
            error: {
              code: error.code || 'IMPORT_FAILED',
              message: error.message,
            },
          },
          null,
          2
        )
      );
    } else {
      console.error(
        `[catalog-import] FAILED (${error.code || 'IMPORT_FAILED'}): ${error.message}`
      );
    }
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  DEV_DATABASE,
  REQUIRED_TABLES,
  REQUIRED_COLUMNS,
  ImportError,
  assertSafeTarget,
  preflight,
  loadSnapshot,
  applyPlan,
  runImport,
  parseArgs,
};
