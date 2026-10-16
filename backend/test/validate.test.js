'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { validateBody, validateQuery } = require('../src/lib/validate');
const { AppError } = require('../src/lib/errors');

const schema = {
  firstName: { type: 'string', min: 1, max: 60, collapse: true },
  lastName: { type: 'string', min: 1, max: 60, collapse: true },
  phone: { type: 'phone' },
};

test('accepts valid body and normalizes names and phone', () => {
  const out = validateBody(
    { firstName: '  Иван ', lastName: 'Петров   Петров', phone: '0881 234 567' },
    schema
  );
  assert.deepEqual(out, {
    firstName: 'Иван',
    lastName: 'Петров Петров',
    phone: '+359881234567',
  });
});

test('rejects missing required fields', () => {
  assert.throws(
    () => validateBody({ firstName: 'Иван', phone: '+359881234567' }, schema),
    (error) => error instanceof AppError && error.status === 400 && error.code === 'VALIDATION_ERROR'
  );
});

test('rejects empty and non-string fields', () => {
  assert.throws(() => validateBody({ firstName: '   ', lastName: 'X', phone: '0881234567' }, schema), AppError);
  assert.throws(() => validateBody({ firstName: 5, lastName: 'X', phone: '0881234567' }, schema), AppError);
});

test('rejects unknown fields with VALIDATION_ERROR', () => {
  assert.throws(
    () =>
      validateBody(
        { firstName: 'И', lastName: 'П', phone: '0881234567', role: 'ADMIN' },
        schema
      ),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
});

test('rejects malformed phone values', () => {
  assert.throws(
    () => validateBody({ firstName: 'И', lastName: 'П', phone: 'not-a-phone' }, schema),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
});

test('does not echo sensitive submitted values in error messages', () => {
  const secret = 'SuperSecretPassword123!';
  try {
    validateBody({ phone: '0881234567', password: secret, extra: secret }, {
      phone: { type: 'phone' },
      password: { type: 'string', min: 1 },
    });
    assert.fail('expected validation error');
  } catch (error) {
    assert.ok(error instanceof AppError);
    assert.ok(!error.message.includes(secret));
  }
});

test('enforces maximum length limits', () => {
  assert.throws(
    () => validateBody({ firstName: 'A'.repeat(61), lastName: 'П', phone: '0881234567' }, schema),
    AppError
  );
});

const intArraySchema = { userIds: { type: 'intArray', maxItems: 3 } };

test('accepts a valid int array and copies it', () => {
  const input = [3, 1, 2];
  const out = validateBody({ userIds: input }, intArraySchema);
  assert.deepEqual(out.userIds, [3, 1, 2]);
  assert.notEqual(out.userIds, input);
});

test('accepts an empty int array', () => {
  const out = validateBody({ userIds: [] }, intArraySchema);
  assert.deepEqual(out.userIds, []);
});

test('rejects duplicate ids', () => {
  assert.throws(
    () => validateBody({ userIds: [1, 2, 1] }, intArraySchema),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
});

test('rejects non-positive, fractional, non-number and unsafe elements', () => {
  const cases = [
    [0],
    [-1],
    [1.5],
    ['1'],
    [null],
    [true],
    [NaN],
    [Number.MAX_SAFE_INTEGER + 1],
    [1, 'x'],
  ];
  for (const userIds of cases) {
    assert.throws(
      () => validateBody({ userIds }, intArraySchema),
      (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR',
      JSON.stringify(userIds)
    );
  }
});

test('rejects a missing, null or non-array value', () => {
  const cases = [{}, { userIds: null }, { userIds: '1' }, { userIds: 1 }, { userIds: {} }];
  for (const body of cases) {
    assert.throws(
      () => validateBody(body, intArraySchema),
      (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR',
      JSON.stringify(body)
    );
  }
});

test('enforces minItems and maxItems boundaries', () => {
  assert.doesNotThrow(() => validateBody({ userIds: [1, 2, 3] }, intArraySchema));
  assert.throws(
    () => validateBody({ userIds: [1, 2, 3, 4] }, intArraySchema),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );

  assert.throws(
    () => validateBody({ userIds: [] }, { userIds: { type: 'intArray', minItems: 1 } }),
    AppError
  );
});

test('does not echo array element values in error messages', () => {
  const secret = 987654321;
  try {
    validateBody({ userIds: [secret, secret] }, intArraySchema);
    assert.fail('expected validation error');
  } catch (error) {
    assert.ok(error instanceof AppError);
    assert.ok(!error.message.includes(String(secret)));
  }
});

const nullableSchema = {
  name: { type: 'string', min: 1, max: 20 },
  category: { type: 'string', min: 1, max: 20, required: false, nullable: true },
};

test('accepts explicit null only for nullable optional fields', () => {
  const out = validateBody({ name: 'Ориз', category: null }, nullableSchema);
  assert.equal(out.category, null);
});

test('treats null as absent for non-nullable optional fields', () => {
  const out = validateBody({ name: 'Ориз' }, {
    name: { type: 'string', min: 1, max: 20 },
    category: { type: 'string', min: 1, max: 20, required: false },
  });
  assert.equal(out.category, undefined);
});

test('rejects null for required fields even when nullable', () => {
  assert.throws(
    () => validateBody({ name: null, category: null }, nullableSchema),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
});

test('still rejects empty and oversized nullable strings', () => {
  assert.throws(() => validateBody({ name: 'X', category: '   ' }, nullableSchema), AppError);
  assert.throws(() => validateBody({ name: 'X', category: 'A'.repeat(21) }, nullableSchema), AppError);
});

const decimalSchema = {
  unitValue: { type: 'decimal', required: false, nullable: true },
};

test('accepts in-range decimals with up to three fractional digits', () => {
  for (const value of [0, 1, 0.5, 1.234, 9999999.999]) {
    const out = validateBody({ unitValue: value }, decimalSchema);
    assert.equal(out.unitValue, value);
  }
});

test('accepts an explicit null decimal', () => {
  const out = validateBody({ unitValue: null }, decimalSchema);
  assert.equal(out.unitValue, null);
});

test('rejects out-of-range, over-precise and non-number decimals', () => {
  const cases = [
    -1,
    1.2345,
    10000000,
    1e-7,
    '1',
    true,
    [],
    {},
    NaN,
    Infinity,
  ];
  for (const unitValue of cases) {
    assert.throws(
      () => validateBody({ unitValue }, decimalSchema),
      (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR',
      JSON.stringify(unitValue)
    );
  }
});

test('enforces decimal min and max overrides', () => {
  const schema = { unitValue: { type: 'decimal', min: 2, max: 5 } };
  assert.doesNotThrow(() => validateBody({ unitValue: 2 }, schema));
  assert.doesNotThrow(() => validateBody({ unitValue: 5 }, schema));
  assert.throws(() => validateBody({ unitValue: 1.999 }, schema), AppError);
  assert.throws(() => validateBody({ unitValue: 5.001 }, schema), AppError);
});

const intSchema = { quantity: { type: 'int', min: 0, max: 2147483647 } };

test('accepts safe integers within range including the boundaries', () => {
  for (const quantity of [0, 1, 12, 2147483647]) {
    const out = validateBody({ quantity }, intSchema);
    assert.equal(out.quantity, quantity);
  }
});

test('defaults the int minimum to 1 for identifiers', () => {
  const schema = { locationId: { type: 'int' } };
  assert.equal(validateBody({ locationId: 1 }, schema).locationId, 1);
  assert.throws(
    () => validateBody({ locationId: 0 }, schema),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
});

test('rejects out-of-range integers', () => {
  assert.throws(
    () => validateBody({ quantity: -1 }, intSchema),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
  assert.throws(
    () => validateBody({ quantity: 2147483648 }, intSchema),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
});

test('rejects non-integer, non-number and unsafe values', () => {
  const cases = [1.5, '5', true, null, [], {}, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1];
  for (const quantity of cases) {
    assert.throws(
      () => validateBody({ quantity }, { quantity: { type: 'int', min: 0 } }),
      (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR',
      JSON.stringify(quantity)
    );
  }
});

test('rejects a missing required int and honours undefined optional ints', () => {
  assert.throws(
    () => validateBody({}, { quantity: { type: 'int', min: 0 } }),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
  const out = validateBody({}, { quantity: { type: 'int', min: 0, required: false } });
  assert.equal(out.quantity, undefined);
});

test('does not echo out-of-range int values in error messages', () => {
  const secret = 3141592653;
  try {
    validateBody({ quantity: secret }, { quantity: { type: 'int', min: 0, max: 2147483647 } });
    assert.fail('expected validation error');
  } catch (error) {
    assert.ok(error instanceof AppError);
    assert.ok(!error.message.includes(String(secret)));
  }
});

const dateSchema = { date: { type: 'date' } };

test('accepts real calendar dates in YYYY-MM-DD form', () => {
  for (const date of ['2026-01-01', '2026-02-28', '2024-02-29', '2026-12-31']) {
    const out = validateBody({ date }, dateSchema);
    assert.equal(out.date, date);
  }
});

test('rejects malformed and impossible calendar dates', () => {
  const cases = [
    '2026-2-3',
    '2026/01/01',
    '01-01-2026',
    '2026-13-01',
    '2026-00-10',
    '2026-02-30',
    '2025-02-29',
    '2026-04-31',
    '20260101',
    '',
    20260101,
  ];
  for (const date of cases) {
    assert.throws(
      () => validateBody({ date }, dateSchema),
      (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR',
      JSON.stringify(date)
    );
  }
});

const timeSchema = { startTime: { type: 'time' } };

test('accepts and normalizes HH:MM and HH:MM:SS times', () => {
  assert.equal(validateBody({ startTime: '09:30' }, timeSchema).startTime, '09:30:00');
  assert.equal(validateBody({ startTime: '09:30:15' }, timeSchema).startTime, '09:30:15');
  assert.equal(validateBody({ startTime: '00:00' }, timeSchema).startTime, '00:00:00');
  assert.equal(validateBody({ startTime: '23:59:59' }, timeSchema).startTime, '23:59:59');
});

test('rejects malformed or out-of-range times', () => {
  const cases = ['9:30', '24:00', '23:60', '23:59:60', '0930', '09:30:15.5', '', 930, null];
  for (const startTime of cases) {
    assert.throws(
      () => validateBody({ startTime }, timeSchema),
      (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR',
      JSON.stringify(startTime)
    );
  }
});

test('validates date and time query parameters', () => {
  const query = validateQuery(
    { date: '2026-11-01', startTime: '09:30' },
    { date: { type: 'date' }, startTime: { type: 'time' } }
  );
  assert.deepEqual(query, { date: '2026-11-01', startTime: '09:30:00' });

  assert.throws(
    () => validateQuery({ date: '2026-02-30' }, { date: { type: 'date' } }),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
  assert.throws(
    () => validateQuery({ startTime: '25:00' }, { startTime: { type: 'time' } }),
    (error) => error instanceof AppError && error.code === 'VALIDATION_ERROR'
  );
});
