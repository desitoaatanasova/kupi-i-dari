'use strict';

// Entry window for volunteer quantity submission (Phase 8).
//
// The window opens at the shift's start datetime and closes at the shift's
// end datetime plus GRACE_MINUTES, inclusive at both ends. Shifts are
// same-day only (Phase 7 invariant), so a window is built from one calendar
// date plus the stored HH:MM:SS times. Local `Date` parsing of
// "YYYY-MM-DDTHH:MM:SS" follows the server timezone (Europe/Sofia in this
// project); the ISO formatter below renders the same instant with the
// Sofia UTC offset for API responses. Clock injection happens at the service
// boundary (callers pass `now`); the module never monkey-patches globals.

const TIMEZONE = 'Europe/Sofia';
const GRACE_MINUTES = 30;

// Accept either the safe shift shape ({ date, startTime, endTime }) or the
// raw database row ({ shift_date, start_time, end_time }).
function getEntryWindow(shift) {
  const date = shift.date !== undefined ? shift.date : shift.shift_date;
  const startTime = shift.startTime !== undefined ? shift.startTime : shift.start_time;
  const endTime = shift.endTime !== undefined ? shift.endTime : shift.end_time;

  // Dateless time strings would be parsed as UTC; the date prefix makes
  // "YYYY-MM-DDTHH:MM:SS" parse as a local (Europe/Sofia) datetime.
  const opensAt = new Date(`${date}T${startTime}`);
  const closesAt = new Date(`${date}T${endTime}`);
  closesAt.setMinutes(closesAt.getMinutes() + GRACE_MINUTES);

  return { opensAt, closesAt };
}

// Inclusive at both ends: opensAt <= now <= closesAt.
function isWithinEntryWindow(shift, now = new Date()) {
  const { opensAt, closesAt } = getEntryWindow(shift);
  return now.getTime() >= opensAt.getTime() && now.getTime() <= closesAt.getTime();
}

// Format a Date as an ISO-8601 timestamp in Europe/Sofia local time with the
// active UTC offset (+02:00 in summer, +03:00 in winter), e.g.
// "2026-05-01T09:00:00+03:00". Deterministic given the IANA tz database.
function toSofiaIso(date) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: TIMEZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
    timeZoneName: 'longOffset',
  }).formatToParts(date);
  const get = (type) => parts.find((part) => part.type === type).value;
  let offset = get('timeZoneName').replace('GMT', '');
  if (offset === '') offset = '+00:00';
  return (
    `${get('year')}-${get('month')}-${get('day')}` +
    `T${get('hour')}:${get('minute')}:${get('second')}${offset}`
  );
}

module.exports = {
  TIMEZONE,
  GRACE_MINUTES,
  getEntryWindow,
  isWithinEntryWindow,
  toSofiaIso,
};
