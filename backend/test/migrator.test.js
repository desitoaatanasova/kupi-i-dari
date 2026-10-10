'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

require('./helpers/env');
const { getTestConnection } = require('./helpers/db');
const { runMigrations } = require('../src/lib/migrator');

const silentLogger = { info() {}, warn() {}, error() {} };

test('migrator applies in order, is idempotent, and rejects checksum drift', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kid-mig-'));
  fs.writeFileSync(
    path.join(dir, '001_first.sql'),
    'CREATE TABLE IF NOT EXISTS kid_mig_a (id INT PRIMARY KEY);'
  );
  fs.writeFileSync(
    path.join(dir, '002_second.sql'),
    'CREATE TABLE IF NOT EXISTS kid_mig_b (id INT PRIMARY KEY);'
  );

  const connection = await getTestConnection();
  const trackingTable = 'schema_migrations_scratch';

  t.after(async () => {
    await connection.query(`DROP TABLE IF EXISTS \`${trackingTable}\``);
    await connection.query('DROP TABLE IF EXISTS kid_mig_a');
    await connection.query('DROP TABLE IF EXISTS kid_mig_b');
    await connection.end();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  const first = await runMigrations({
    connection,
    migrationsDir: dir,
    trackingTable,
    logger: silentLogger,
  });
  assert.equal(first.applied, 2);

  const second = await runMigrations({
    connection,
    migrationsDir: dir,
    trackingTable,
    logger: silentLogger,
  });
  assert.equal(second.applied, 0);

  fs.writeFileSync(
    path.join(dir, '002_second.sql'),
    'CREATE TABLE IF NOT EXISTS kid_mig_b (id INT PRIMARY KEY, note VARCHAR(10));'
  );

  await assert.rejects(
    () =>
      runMigrations({
        connection,
        migrationsDir: dir,
        trackingTable,
        logger: silentLogger,
      }),
    /Checksum mismatch/
  );
});
