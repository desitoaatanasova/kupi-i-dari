'use strict';

// Destructive helper: drops and recreates ONLY the test database, then runs
// migrations. Refuses to run unless the target name looks like a test database.
//
// Usage: npm run db:reset:test

require('dotenv').config();

const mysql = require('mysql2/promise');
const config = require('../src/config');
const { runMigrations } = require('../src/lib/migrator');

async function main() {
  const target = config.dbTest;
  if (!/_test$/i.test(target)) {
    throw new Error(
      `Refusing to drop "${target}": target name must end with "_test".`
    );
  }

  const admin = await mysql.createConnection({
    host: config.db.host,
    port: config.db.port,
    user: config.db.user,
    password: config.db.password,
    multipleStatements: true,
  });

  try {
    console.log(`[db:reset:test] dropping and recreating "${target}"`);
    await admin.query(`DROP DATABASE IF EXISTS \`${target}\``);
    await admin.query(
      `CREATE DATABASE \`${target}\` ` +
        'CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'
    );
  } finally {
    await admin.end();
  }

  const connection = await mysql.createConnection({
    host: config.db.host,
    port: config.db.port,
    user: config.db.user,
    password: config.db.password,
    database: target,
    charset: config.db.charset,
    multipleStatements: true,
  });

  try {
    const result = await runMigrations({
      connection,
      migrationsDir: config.migrationsDir,
    });
    console.log(
      `[db:reset:test] done for "${target}": ` +
        `${result.applied} applied, ${result.total} total`
    );
  } finally {
    await connection.end();
  }
}

main().catch((error) => {
  console.error(`[db:reset:test] FAILED: ${error.message}`);
  process.exit(1);
});
