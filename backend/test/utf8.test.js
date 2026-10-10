'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const { getTestConnection } = require('./helpers/db');

test('UTF-8 Bulgarian text round-trips through the database', async (t) => {
  const connection = await getTestConnection();
  t.after(async () => {
    await connection.query('DROP TABLE IF EXISTS kid_utf8_probe');
    await connection.end();
  });

  await connection.query(
    'CREATE TABLE kid_utf8_probe (id INT PRIMARY KEY, label VARCHAR(100) ' +
      'CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL) ' +
      'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'
  );

  const samples = ['Купи и Дари', 'Пловдив', 'Отговорник'];
  for (let i = 0; i < samples.length; i += 1) {
    await connection.query('INSERT INTO kid_utf8_probe (id, label) VALUES (?, ?)', [
      i + 1,
      samples[i],
    ]);
  }

  const [rows] = await connection.query(
    'SELECT id, label FROM kid_utf8_probe ORDER BY id'
  );
  assert.deepEqual(
    rows.map((row) => row.label),
    samples
  );
  for (const row of rows) {
    assert.ok(!row.label.includes('?'), `unexpected corruption: ${row.label}`);
  }
});
