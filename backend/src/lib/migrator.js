'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function checksum(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

async function ensureTrackingTable(connection, trackingTable) {
  await connection.query(
    `CREATE TABLE IF NOT EXISTS \`${trackingTable}\` (
       filename   VARCHAR(255) NOT NULL,
       checksum   CHAR(64)     NOT NULL,
       applied_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
       PRIMARY KEY (filename)
     ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`
  );
}

async function runMigrations(options) {
  const {
    connection,
    migrationsDir,
    trackingTable = 'schema_migrations',
    logger = console,
  } = options || {};

  if (!connection) {
    throw new Error('runMigrations requires a database connection');
  }
  if (!migrationsDir || !fs.existsSync(migrationsDir)) {
    throw new Error(`Migrations directory not found: ${migrationsDir}`);
  }

  const files = fs
    .readdirSync(migrationsDir)
    .filter((name) => name.toLowerCase().endsWith('.sql'))
    .sort((a, b) => a.localeCompare(b, 'en'));

  await ensureTrackingTable(connection, trackingTable);

  const [rows] = await connection.query(
    `SELECT filename, checksum FROM \`${trackingTable}\``
  );
  const applied = new Map(rows.map((row) => [row.filename, row.checksum]));

  for (const name of applied.keys()) {
    if (!files.includes(name)) {
      logger.warn(`[migrate] recorded migration has no matching file: ${name}`);
    }
  }

  let appliedCount = 0;
  for (const file of files) {
    const fullPath = path.join(migrationsDir, file);
    const buffer = fs.readFileSync(fullPath);
    const fileChecksum = checksum(buffer);

    if (applied.has(file)) {
      const recordedChecksum = applied.get(file);
      if (recordedChecksum !== fileChecksum) {
        throw new Error(
          `Checksum mismatch for already-applied migration "${file}". ` +
            `Recorded=${recordedChecksum} file=${fileChecksum}. ` +
            'Refusing to silently apply a changed migration. Restore the ' +
            'original file or add a new forward migration instead.'
        );
      }
      logger.info(`[migrate] up to date: ${file}`);
      continue;
    }

    logger.info(`[migrate] applying: ${file}`);
    try {
      await connection.query(buffer.toString('utf8'));
      await connection.query(
        `INSERT INTO \`${trackingTable}\` (filename, checksum) VALUES (?, ?)`,
        [file, fileChecksum]
      );
      appliedCount += 1;
    } catch (error) {
      throw new Error(`Migration failed "${file}": ${error.message}`);
    }
  }

  return { applied: appliedCount, total: files.length };
}

module.exports = { checksum, runMigrations };
