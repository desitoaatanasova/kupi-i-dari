'use strict';

const { AppError } = require('./errors');
const { tryNormalizePhone } = require('./phone');

function fail(message) {
  throw new AppError(400, 'VALIDATION_ERROR', message);
}

function rejectUnknownFields(obj, schema) {
  const allowed = Object.keys(schema);
  const unexpected = Object.keys(obj).filter((key) => !allowed.includes(key));
  if (unexpected.length > 0) {
    fail(`Unexpected field(s): ${unexpected.join(', ')}.`);
  }
}

function enumValue(field, value, rules) {
  const values = Array.isArray(rules.values) ? rules.values : [];
  if (!values.includes(value)) {
    fail(`${field} must be one of: ${values.join(', ')}.`);
  }
  return value;
}

// Validate a request body against an exact schema. Unknown fields are rejected.
// Each schema entry:
//   { type: 'string'|'phone'|'enum'|'boolean'|'int'|'intArray'|'decimal'|'date'|'time',
//     required?, min?, max?, collapse?, values?, maxItems?, minItems?, nullable? }
// Optional fields accept an explicit `null` only when `nullable: true`, which is
// how a nullable column is cleared; otherwise `null` is treated as absent.
// Error messages reference the field name only and never echo its value.
function validateBody(body, schema) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    fail('Request body must be a JSON object.');
  }

  rejectUnknownFields(body, schema);

  const result = {};
  for (const field of Object.keys(schema)) {
    result[field] = validateField(field, body[field], schema[field]);
  }
  return result;
}

// Strict decimal parser for JSON numbers: rejects non-numbers (including
// numeric strings), non-finite values, scientific notation, out-of-range values
// and more than `places` fractional digits. Returned as a plain number.
function validateDecimal(field, value, rules) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    fail(`${field} must be a number.`);
  }
  const min = rules.min !== undefined ? rules.min : 0;
  const max = rules.max !== undefined ? rules.max : 9999999.999;
  if (value < min) fail(`${field} must be at least ${min}.`);
  if (value > max) fail(`${field} must be at most ${max}.`);
  const places = rules.places !== undefined ? rules.places : 3;
  const text = String(value);
  if (text.includes('e') || text.includes('E')) {
    fail(`${field} must not use scientific notation.`);
  }
  const dot = text.indexOf('.');
  if (dot !== -1 && text.length - dot - 1 > places) {
    fail(`${field} must have at most ${places} decimal places.`);
  }
  return value;
}

// Strict integer validator for JSON bodies: accepts only safe integers (never
// numeric strings, booleans, floats or unsafe integers). `min` defaults to 1
// (identifiers); pass `min: 0` for values such as quantities. `max` is optional.
function validateInt(field, value, rules) {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    fail(`${field} must be an integer.`);
  }
  const min = rules.min !== undefined ? rules.min : 1;
  if (value < min) fail(`${field} must be at least ${min}.`);
  if (rules.max !== undefined && value > rules.max) {
    fail(`${field} must be at most ${rules.max}.`);
  }
  return value;
}

// Strict calendar-date parser: only `YYYY-MM-DD` with a real calendar date is
// accepted (2026-02-30 is rejected). Returned unchanged as the canonical string.
function validateDate(field, value) {
  if (typeof value !== 'string') fail(`${field} must be a string.`);
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) fail(`${field} must be a calendar date in YYYY-MM-DD format.`);
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12) fail(`${field} must be a valid calendar date.`);
  const daysInMonth = [
    31,
    year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28,
    31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
  ];
  if (day < 1 || day > daysInMonth[month - 1]) {
    fail(`${field} must be a valid calendar date.`);
  }
  return `${match[1]}-${match[2]}-${match[3]}`;
}

// Strict time-of-day parser: accepts `HH:MM` or `HH:MM:SS` (24-hour clock) and
// normalises to the canonical `HH:MM:SS` form.
function validateTime(field, value) {
  if (typeof value !== 'string') fail(`${field} must be a string.`);
  const match = /^(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!match) fail(`${field} must be a time in HH:MM or HH:MM:SS format.`);
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  const second = match[3] === undefined ? 0 : Number(match[3]);
  if (hour > 23) fail(`${field} must be a valid time of day.`);
  if (minute > 59) fail(`${field} must be a valid time of day.`);
  if (second > 59) fail(`${field} must be a valid time of day.`);
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(hour)}:${pad(minute)}:${pad(second)}`;
}

function validateField(field, value, rules) {
  const required = rules.required !== false;
  const type = rules.type || 'string';

  if (value === undefined) {
    if (required) fail(`${field} is required.`);
    return undefined;
  }

  if (value === null) {
    if (required) fail(`${field} is required.`);
    if (rules.nullable) return null;
    return undefined;
  }

  if (type === 'phone') {
    if (typeof value !== 'string') fail(`${field} must be a string.`);
    const canonical = tryNormalizePhone(value);
    if (canonical === null) fail(`${field} is not a valid Bulgarian phone number.`);
    return canonical;
  }

  if (type === 'enum') {
    if (typeof value !== 'string') fail(`${field} must be a string.`);
    return enumValue(field, value, rules);
  }

  if (type === 'boolean') {
    if (typeof value !== 'boolean') fail(`${field} must be a boolean.`);
    return value;
  }

  if (type === 'int') {
    return validateInt(field, value, rules);
  }

  if (type === 'decimal') {
    return validateDecimal(field, value, rules);
  }

  if (type === 'date') {
    return validateDate(field, value);
  }

  if (type === 'time') {
    return validateTime(field, value);
  }

  if (type === 'intArray') {
    if (!Array.isArray(value)) fail(`${field} must be an array.`);
    const maxItems = rules.maxItems !== undefined ? rules.maxItems : 100;
    const minItems = rules.minItems !== undefined ? rules.minItems : 0;
    if (value.length < minItems) {
      fail(`${field} must contain at least ${minItems} item(s).`);
    }
    if (value.length > maxItems) {
      fail(`${field} must contain at most ${maxItems} item(s).`);
    }
    const seen = new Set();
    for (const item of value) {
      if (typeof item !== 'number' || !Number.isSafeInteger(item) || item <= 0) {
        fail(`${field} must contain only positive integers.`);
      }
      if (seen.has(item)) fail(`${field} must not contain duplicate ids.`);
      seen.add(item);
    }
    return value.slice();
  }

  if (type !== 'string') {
    fail(`Unsupported validation type for ${field}.`);
  }

  if (typeof value !== 'string') fail(`${field} must be a string.`);

  let text = value;
  if (rules.trim !== false) text = text.trim();
  if (rules.collapse) text = text.replace(/\s+/g, ' ');

  if (text.length === 0) fail(`${field} must not be empty.`);
  if (rules.min !== undefined && text.length < rules.min) {
    fail(`${field} must be at least ${rules.min} characters.`);
  }
  if (rules.max !== undefined && text.length > rules.max) {
    fail(`${field} must be at most ${rules.max} characters.`);
  }

  return text;
}

// Validate query-string parameters against an exact schema. Query values arrive
// as strings, so each entry is parsed from that representation rather than
// coerced: { type: 'int'|'boolean'|'enum'|'date'|'time', required?, min?, max?, values? }.
// Optional by default (unlike body fields). Rejected values never echo input.
function validateQuery(query, schema) {
  if (query === null || typeof query !== 'object' || Array.isArray(query)) {
    fail('Query parameters must be an object.');
  }

  rejectUnknownFields(query, schema);

  const result = {};
  for (const field of Object.keys(schema)) {
    result[field] = validateQueryField(field, query[field], schema[field]);
  }
  return result;
}

function validateQueryField(field, value, rules) {
  const required = rules.required === true;
  const type = rules.type || 'enum';

  if (value === undefined) {
    if (required) fail(`${field} is required.`);
    return undefined;
  }

  // Express parses a repeated parameter into an array; only a single value is
  // accepted. Non-strings (nested objects from the query parser) are rejected.
  if (typeof value !== 'string') {
    fail(`${field} must be provided at most once as a single value.`);
  }
  if (value.length === 0) fail(`${field} must not be empty.`);

  if (type === 'int') return validateIntQuery(field, value, rules);
  if (type === 'boolean') return validateBooleanQuery(field, value);
  if (type === 'enum') return enumValue(field, value, rules);
  if (type === 'date') return validateDate(field, value);
  if (type === 'time') return validateTime(field, value);

  fail(`Unsupported validation type for ${field}.`);
}

// Strict positive-integer parser: only canonical decimal digits are accepted, so
// values like "1.5", "-1", "1e3", "abc" or " 1 " are rejected rather than coerced.
function validateIntQuery(field, value, rules) {
  if (!/^\d+$/.test(value)) fail(`${field} must be a positive integer.`);
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed)) fail(`${field} must be a positive integer.`);
  const min = rules.min !== undefined ? rules.min : 1;
  if (parsed < min) fail(`${field} must be at least ${min}.`);
  if (rules.max !== undefined && parsed > rules.max) {
    fail(`${field} must be at most ${rules.max}.`);
  }
  return parsed;
}

function validateBooleanQuery(field, value) {
  if (value === 'true') return true;
  if (value === 'false') return false;
  fail(`${field} must be "true" or "false".`);
}

module.exports = { validateBody, validateQuery };
