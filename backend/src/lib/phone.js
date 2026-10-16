'use strict';

// Phone helpers for Bulgarian numbers.
//
// Canonical representation: "+359" followed by exactly 9 digits, e.g.
// "+359881234567". Accepted inputs:
//   * +359XXXXXXXXX
//   * 00359XXXXXXXXX
//   * 0XXXXXXXXX  (national trunk form)
// with optional spaces, hyphens and parentheses as visual separators.
//
// This is deliberately a format normaliser, not a carrier/line-type validator.

const CANONICAL_PATTERN = /^\+359[2-9]\d{8}$/;
const SEPARATORS = /[\s\-()]/g;

class PhoneError extends Error {
  constructor(message) {
    super(message);
    this.name = 'PhoneError';
    this.code = 'INVALID_PHONE';
  }
}

// Collapse every accepted representation to canonical "+359XXXXXXXXX".
// Returns null when the input is not a string.
function tryNormalizePhone(input) {
  if (typeof input !== 'string') return null;

  const compact = input.replace(SEPARATORS, '');
  if (compact.length === 0) return null;
  // Only digits and a single optional leading "+" are meaningful now.
  if (!/^\+?\d+$/.test(compact)) return null;

  let national;
  if (/^\+359\d{9}$/.test(compact)) {
    national = compact.slice(4);
  } else if (/^00359\d{9}$/.test(compact)) {
    national = compact.slice(5);
  } else if (/^0\d{9}$/.test(compact)) {
    national = compact.slice(1);
  } else {
    return null;
  }

  const canonical = `+359${national}`;
  return CANONICAL_PATTERN.test(canonical) ? canonical : null;
}

function normalizePhone(input) {
  const canonical = tryNormalizePhone(input);
  if (canonical === null) {
    throw new PhoneError('Not a valid Bulgarian phone number.');
  }
  return canonical;
}

function isValidPhone(input) {
  return tryNormalizePhone(input) !== null;
}

// Mask a phone number for diagnostics. Never returns the full number.
function maskPhone(input) {
  const canonical = tryNormalizePhone(input);
  if (canonical === null) return '***';
  const digits = canonical.slice(4); // 9 digits
  return `+359${digits[0]}${'*'.repeat(5)}${digits.slice(6)}`;
}

module.exports = {
  PhoneError,
  normalizePhone,
  tryNormalizePhone,
  isValidPhone,
  maskPhone,
};
