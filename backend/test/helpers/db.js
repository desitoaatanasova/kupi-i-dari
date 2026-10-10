'use strict';

require('./env');

const mysql = require('mysql2/promise');
const config = require('../../src/config');
const { runMigrations } = require('../../src/lib/migrator');

async function getTestConnection() {
  return mysql.createConnection({
    host: config.db.host,
    port: config.db.port,
    user: config.db.user,
    password: config.db.password,
    database: config.db.name,
    charset: config.db.charset,
    multipleStatements: true,
  });
}

async function ensureMigrated() {
  const connection = await getTestConnection();
  try {
    await runMigrations({
      connection,
      migrationsDir: config.migrationsDir,
      logger: { info() {}, warn() {}, error() {} },
    });
  } finally {
    await connection.end();
  }
}

module.exports = { getTestConnection, ensureMigrated, config };
