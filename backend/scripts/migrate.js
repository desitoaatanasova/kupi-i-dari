'use strict';

require('dotenv').config();

const mysql = require('mysql2/promise');
const config = require('../src/config');
const { runMigrations } = require('../src/lib/migrator');

async function main() {
  const connection = await mysql.createConnection({
    host: config.db.host,
    port: config.db.port,
    user: config.db.user,
    password: config.db.password,
    database: config.db.name,
    charset: config.db.charset,
    multipleStatements: true,
  });

  try {
    const result = await runMigrations({
      connection,
      migrationsDir: config.migrationsDir,
    });
    console.log(
      `[migrate] done for database "${config.db.name}": ` +
        `${result.applied} applied, ${result.total} total`
    );
  } finally {
    await connection.end();
  }
}

main().catch((error) => {
  console.error(`[migrate] FAILED: ${error.message}`);
  process.exit(1);
});
