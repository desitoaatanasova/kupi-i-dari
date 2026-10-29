'use strict';

const { AppError } = require('../lib/errors');
const { verifyToken } = require('../lib/jwt');
const users = require('../services/users');

const UNAUTHORIZED = () =>
  new AppError(401, 'UNAUTHORIZED', 'Authentication required.');

function extractBearerToken(req) {
  const header = req.headers.authorization;
  if (typeof header !== 'string') return null;
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  return match ? match[1] : null;
}

// Resolve the bearer token to the current database user and attach the safe
// profile to req.user. Rejects missing/malformed/expired/badly-signed/stale
// tokens with 401 and disabled accounts with 403.
async function authenticate(req, res, next) {
  try {
    const token = extractBearerToken(req);
    if (!token) throw UNAUTHORIZED();

    let payload;
    try {
      payload = verifyToken(token);
    } catch (error) {
      throw UNAUTHORIZED();
    }

    const userId = Number(payload.sub);
    if (!Number.isInteger(userId) || userId <= 0) throw UNAUTHORIZED();

    const user = await users.findById(userId);
    if (!user) throw UNAUTHORIZED();

    if (!user.is_active) {
      throw new AppError(403, 'ACCOUNT_DISABLED', 'This account is disabled.');
    }

    if (Number(payload.tv) !== Number(user.token_version)) {
      throw UNAUTHORIZED();
    }

    // Trust the current database role, not the JWT claim.
    req.user = users.toSafeProfile(user);

    // Every authenticated request re-checks the DB-backed forced-password flag,
    // so staff pending a change are blocked from all protected routes uniformly.
    enforcePasswordChanged(req, res, next);
  } catch (error) {
    next(error);
  }
}

// Reusable role guard for later phases. Must run after `authenticate`.
function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.user) return next(UNAUTHORIZED());
    if (!roles.includes(req.user.role)) {
      return next(
        new AppError(403, 'FORBIDDEN', 'You do not have permission to perform this action.')
      );
    }
    return next();
  };
}

// Endpoints reachable even while a forced password change is pending, so the
// user can change their password, inspect their own profile and sign out.
const PASSWORD_CHANGE_ALLOWLIST = new Set([
  '/api/auth/password/change',
  '/api/auth/me',
  '/api/auth/logout',
]);

// Enforce the DB-backed must_change_password flag. Runs inside `authenticate`
// after req.user is populated. Staff pending a forced change are blocked from
// every protected route except the password-change allowlist.
function enforcePasswordChanged(req, res, next) {
  if (!req.user || !req.user.mustChangePassword) return next();

  const originalUrl = req.originalUrl || req.url || '';
  const path = originalUrl.split('?')[0];

  if (PASSWORD_CHANGE_ALLOWLIST.has(path)) return next();

  return next(
    new AppError(
      403,
      'MUST_CHANGE_PASSWORD',
      'Password change is required before continuing.'
    )
  );
}

module.exports = { authenticate, requireRole };
