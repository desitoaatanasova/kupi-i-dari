'use strict';

require('dotenv').config();

const bcrypt = require('bcryptjs');
const mysql = require('mysql2/promise');
const config = require('../src/config');
const { normalizePhone, maskPhone, PhoneError } = require('../src/lib/phone');

async function main() {
  const { phone: rawPhone, password, firstName, lastName } = config.seedAdmin;

  if (!password) {
    throw new Error(
      'SEED_ADMIN_PASSWORD is not set. Set it in backend/.env before seeding.'
    );
  }

  let phone;
  try {
    phone = normalizePhone(rawPhone);
  } catch (error) {
    if (error instanceof PhoneError) {
      throw new Error('SEED_ADMIN_PHONE is not a valid Bulgarian phone number.');
    }
    throw error;
  }

  const connection = await mysql.createConnection({
    host: config.db.host,
    port: config.db.port,
    user: config.db.user,
    password: config.db.password,
    database: config.db.name,
    charset: config.db.charset,
  });

  try {
    const [existing] = await connection.query(
      'SELECT user_id FROM users WHERE phone = ? LIMIT 1',
      [phone]
    );

    if (existing.length > 0) {
      console.log(
        `[seed:admin] an account with phone ${maskPhone(phone)} already exists ` +
          `(user_id=${existing[0].user_id}); not overwriting.`
      );
      return;
    }

    const passwordHash = await bcrypt.hash(password, 12);
    const [result] = await connection.query(
      `INSERT INTO users (phone, password_hash, first_name, last_name, role, created_by)
       VALUES (?, ?, ?, ?, 'ADMIN', NULL)`,
      [phone, passwordHash, firstName, lastName]
    );

    console.log(
      `[seed:admin] created administrator user_id=${result.insertId} ` +
        `(${firstName} ${lastName}, phone=${maskPhone(phone)}).`
    );
  } finally {
    await connection.end();
  }
}

main().catch((error) => {
  console.error(`[seed:admin] FAILED: ${error.message}`);
  process.exit(1);
});
