'use strict';

const jwt = require('jsonwebtoken');
const config = require('../config');

// Sign an HS256 token with the approved claims: sub, role, tv (token version),
// plus iat/exp added by jsonwebtoken. Expiry is the configured number of seconds.
function signToken(user) {
  return jwt.sign(
    { sub: user.user_id, role: user.role, tv: user.token_version },
    config.jwt.secret,
    { algorithm: 'HS256', expiresIn: config.jwt.expiresInSeconds }
  );
}

// Verify signature, algorithm (HS256 only) and expiry. Throws on any failure.
function verifyToken(token) {
  return jwt.verify(token, config.jwt.secret, { algorithms: ['HS256'] });
}

function expiresInSeconds() {
  return config.jwt.expiresInSeconds;
}

module.exports = { signToken, verifyToken, expiresInSeconds };
