'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizePhone,
  tryNormalizePhone,
  isValidPhone,
  maskPhone,
  PhoneError,
} = require('../src/lib/phone');

test('normalizes +359 format', () => {
  assert.equal(normalizePhone('+359881234567'), '+359881234567');
});

test('normalizes 00359 format', () => {
  assert.equal(normalizePhone('00359881234567'), '+359881234567');
});

test('normalizes Bulgarian national 0 format', () => {
  assert.equal(normalizePhone('0881234567'), '+359881234567');
});

test('equivalent formats normalize to the same value', () => {
  const canonical = '+359881234567';
  for (const input of [
    '+359881234567',
    '00359881234567',
    '0881234567',
    '+359 88 123 4567',
    '+359-88-123-4567',
    '+359 (88) 123-4567',
    '00359 881 234 567',
    '0881 234 567',
  ]) {
    assert.equal(normalizePhone(input), canonical, `input: ${input}`);
  }
});

test('rejects invalid prefixes, lengths, characters and malformed values', () => {
  for (const input of [
    '+1234567890',
    '+449871234567',
    '359881234567',
    '+35988123456',
    '+3598812345678',
    '088123456',
    '08812345678',
    '+359081234567',
    '+359181234567',
    'abc123',
    'phone',
    '+359 88A 123',
    '',
    '   ',
    '+',
    '()',
    '+359881234567+',
  ]) {
    assert.equal(tryNormalizePhone(input), null, `should reject: ${JSON.stringify(input)}`);
    assert.equal(isValidPhone(input), false, `isValidPhone: ${JSON.stringify(input)}`);
    assert.throws(() => normalizePhone(input), PhoneError, `normalizePhone: ${JSON.stringify(input)}`);
  }
});

test('rejects non-string inputs', () => {
  for (const input of [null, undefined, 123, {}, [], true]) {
    assert.equal(tryNormalizePhone(input), null);
    assert.throws(() => normalizePhone(input), PhoneError);
  }
});

test('masking never returns the complete phone number', () => {
  const full = '+359881234567';
  const masked = maskPhone(full);
  assert.notEqual(masked, full);
  assert.equal(masked.includes('881234567'), false);
  assert.match(masked, /^\+359/);
  assert.ok(masked.includes('*'));
  assert.equal(maskPhone('not-a-phone'), '***');
});
