'use strict';

const rateLimit = require('express-rate-limit');
const config = require('../config');

// Structured 429 response. Never logs the request body or credentials.
function rateLimitHandler(req, res) {
  res.status(429).json({
    error: {
      code: 'RATE_LIMITED',
      message: 'Too many requests. Please try again later.',
    },
  });
}

const shared = {
  windowMs: config.authRateLimit.windowMs,
  standardHeaders: true,
  legacyHeaders: false,
  handler: rateLimitHandler,
};

// Staff login: stricter default (10 per window per IP).
const loginLimiter = rateLimit({ ...shared, max: config.authRateLimit.loginMax });

// Volunteer identification: looser default (20 per window per IP).
const volunteerLimiter = rateLimit({
  ...shared,
  max: config.authRateLimit.volunteerMax,
});

// Admin write operations (create/update/status): modest default (30 per IP).
const adminWriteLimiter = rateLimit({
  ...shared,
  max: config.authRateLimit.adminWriteMax,
});

module.exports = { loginLimiter, volunteerLimiter, adminWriteLimiter };
