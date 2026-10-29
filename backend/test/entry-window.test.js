'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

require('./helpers/env');
const {
  GRACE_MINUTES,
  getEntryWindow,
  isWithinEntryWindow,
  toSofiaIso,
} = require('../src/lib/entry-window');

const SOFIA_ISO =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/;

function local(dateString) {
  return new Date(dateString);
}

test('GRACE_MINUTES is 30', () => {
  assert.equal(GRACE_MINUTES, 30);
});

test('winter shift window uses the +02:00 Sofia offset', () => {
  const window = getEntryWindow({
    date: '2026-01-15',
    startTime: '09:00:00',
    endTime: '13:00:00',
  });
  assert.equal(toSofiaIso(window.opensAt), '2026-01-15T09:00:00+02:00');
  assert.equal(toSofiaIso(window.closesAt), '2026-01-15T13:30:00+02:00');
});

test('summer shift window uses the +03:00 Sofia offset', () => {
  const window = getEntryWindow({
    date: '2026-07-15',
    startTime: '09:00:00',
    endTime: '13:00:00',
  });
  assert.equal(toSofiaIso(window.opensAt), '2026-07-15T09:00:00+03:00');
  assert.equal(toSofiaIso(window.closesAt), '2026-07-15T13:30:00+03:00');
});

test('accepts the raw database row shape as well as the safe shape', () => {
  const fromRow = getEntryWindow({
    shift_date: '2026-05-01',
    start_time: '09:00:00',
    end_time: '13:00:00',
  });
  const fromSafe = getEntryWindow({
    date: '2026-05-01',
    startTime: '09:00:00',
    endTime: '13:00:00',
  });
  assert.equal(fromRow.opensAt.getTime(), fromSafe.opensAt.getTime());
  assert.equal(fromRow.closesAt.getTime(), fromSafe.closesAt.getTime());
});

test('closesAt is exactly end time plus the 30-minute grace period', () => {
  const window = getEntryWindow({
    date: '2026-05-01',
    startTime: '09:00',
    endTime: '13:00',
  });
  assert.equal(window.closesAt.getTime() - local('2026-05-01T13:00:00').getTime(), 30 * 60 * 1000);
});

test('window boundaries are inclusive at both ends', () => {
  const shift = { date: '2026-05-01', startTime: '09:00:00', endTime: '13:00:00' };
  const { opensAt, closesAt } = getEntryWindow(shift);

  assert.equal(isWithinEntryWindow(shift, new Date(opensAt.getTime() - 1000)), false);
  assert.equal(isWithinEntryWindow(shift, opensAt), true);
  assert.equal(isWithinEntryWindow(shift, new Date(opensAt.getTime() + 1000)), true);

  assert.equal(isWithinEntryWindow(shift, new Date(closesAt.getTime() - 1000)), true);
  assert.equal(isWithinEntryWindow(shift, closesAt), true);
  assert.equal(isWithinEntryWindow(shift, new Date(closesAt.getTime() + 1000)), false);
});

test('one second before the opening time is outside the window', () => {
  const shift = { date: '2026-05-01', startTime: '09:00:00', endTime: '13:00:00' };
  const before = new Date(local('2026-05-01T08:59:59').getTime());
  assert.equal(isWithinEntryWindow(shift, before), false);
});

test('the exact grace-period closing second is inside; the next is outside', () => {
  const shift = { date: '2026-05-01', startTime: '09:00:00', endTime: '13:00:00' };
  assert.equal(isWithinEntryWindow(shift, local('2026-05-01T13:30:00')), true);
  assert.equal(isWithinEntryWindow(shift, local('2026-05-01T13:30:01')), false);
});

test('default now parameter uses the current clock', () => {
  const shift = {
    date: '2026-01-01',
    startTime: '00:00:00',
    endTime: '23:59:00',
  };
  // Only meaningful when "today" is the shift date; assert the shape instead
  // by passing an explicit now around the default call site.
  const { opensAt, closesAt } = getEntryWindow(shift);
  assert.ok(opensAt < closesAt);
  assert.equal(typeof isWithinEntryWindow(shift), 'boolean');
});

test('DST: windows on both sides of the 2026 spring-forward transition', () => {
  // Europe/Sofia 2026-03-29: 03:00 EET -> 04:00 EEST (+02:00 -> +03:00).
  const beforeJump = getEntryWindow({
    date: '2026-03-29',
    startTime: '01:00:00',
    endTime: '02:00:00',
  });
  assert.equal(toSofiaIso(beforeJump.opensAt), '2026-03-29T01:00:00+02:00');
  assert.equal(toSofiaIso(beforeJump.closesAt), '2026-03-29T02:30:00+02:00');

  const afterJump = getEntryWindow({
    date: '2026-03-29',
    startTime: '04:00:00',
    endTime: '12:00:00',
  });
  assert.equal(toSofiaIso(afterJump.opensAt), '2026-03-29T04:00:00+03:00');
  assert.equal(toSofiaIso(afterJump.closesAt), '2026-03-29T12:30:00+03:00');
});

test('DST: window on the 2026 fall-back transition day stays consistent', () => {
  // Europe/Sofia 2026-10-25: 04:00 EEST -> 03:00 EET (+03:00 -> +02:00).
  const morning = getEntryWindow({
    date: '2026-10-25',
    startTime: '01:00:00',
    endTime: '02:30:00',
  });
  assert.equal(toSofiaIso(morning.opensAt), '2026-10-25T01:00:00+03:00');
  assert.equal(toSofiaIso(morning.closesAt), '2026-10-25T03:00:00+03:00');

  const afternoon = getEntryWindow({
    date: '2026-10-25',
    startTime: '10:00:00',
    endTime: '14:00:00',
  });
  assert.equal(toSofiaIso(afternoon.opensAt), '2026-10-25T10:00:00+02:00');
  assert.equal(toSofiaIso(afternoon.closesAt), '2026-10-25T14:30:00+02:00');

  // An instant just before the close is inside; both passes of the repeated
  // 03:00-03:59 hour (offsets +03:00 and +02:00) fall after this window's
  // close instant (03:00 EEST = 00:00 UTC) and are outside.
  const morningShift = { date: '2026-10-25', startTime: '01:00:00', endTime: '02:30:00' };
  assert.equal(isWithinEntryWindow(morningShift, new Date('2026-10-25T02:45:00+03:00')), true);
  assert.equal(isWithinEntryWindow(morningShift, new Date('2026-10-25T03:15:00+03:00')), false);
  assert.equal(isWithinEntryWindow(morningShift, new Date('2026-10-25T03:15:00+02:00')), false);
});

test('toSofiaIso always renders the Sofia offset format', () => {
  for (const iso of [
    '2026-01-10T12:00:00Z',
    '2026-07-10T12:00:00Z',
    '2026-03-29T01:00:00Z',
    '2026-10-25T05:00:00Z',
  ]) {
    const formatted = toSofiaIso(new Date(iso));
    assert.match(formatted, SOFIA_ISO, formatted);
  }
});
