'use strict';

const bcrypt = require('bcryptjs');

// Cost factor is intentionally fixed to 12 to match the existing admin seed
// (scripts/seed-admin.js) and migration expectations.
const BCRYPT_COST = 12;

// Fixed, valid bcrypt hash used to burn a comparable amount of time when a
// staff account does not exist, reducing timing-based account enumeration.
// It is a hash of a random value that is not stored anywhere and is never a
// valid credential for any account.
const DUMMY_HASH =
  '$2a$12$2EXZ5sgazHd/.tAzzLhgEOeaXEGVvjlAYEAt0WaJJEODwVu.8f7kO';

function hashPassword(plain) {
  return bcrypt.hash(plain, BCRYPT_COST);
}

// Constant-time-ish comparison via bcrypt. Returns false for a missing hash
// instead of throwing, so callers can keep responses generic.
function verifyPassword(plain, hash) {
  if (typeof hash !== 'string' || hash.length === 0) {
    return Promise.resolve(false);
  }
  return bcrypt.compare(plain, hash);
}

// Perform a dummy comparison and always report failure.
async function verifyWithDummy(plain) {
  await bcrypt.compare(plain, DUMMY_HASH);
  return false;
}

module.exports = {
  BCRYPT_COST,
  DUMMY_HASH,
  hashPassword,
  verifyPassword,
  verifyWithDummy,
};
