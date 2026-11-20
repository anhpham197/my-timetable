import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DAY_END_MINUTE,
  DAY_START_MINUTE,
  nextRequestWindow,
  rangesOverlap,
  timeMinutes,
  timeOptions,
  validateRequestContact,
  validateTimeRange
} from '../timetable-rules.mjs';

test('the supported timetable range is the full day', () => {
  assert.equal(DAY_START_MINUTE, 0);
  assert.equal(DAY_END_MINUTE, 1440);
  assert.equal(timeMinutes('00:00'), 0);
  assert.equal(timeMinutes('24:00'), 1440);
  assert.equal(validateTimeRange('00:00', '00:30'), true);
  assert.equal(validateTimeRange('23:30', '24:00'), true);
});

test('time ranges reject invalid clocks, empty durations, and 24:00 starts', () => {
  assert.equal(validateTimeRange('24:00', '24:00'), false);
  assert.equal(validateTimeRange('23:30', '23:30'), false);
  assert.equal(validateTimeRange('23:30', '00:00'), false);
  assert.equal(validateTimeRange('24:30', '25:00'), false);
  assert.equal(validateTimeRange('08:15', '09:00'), true);
});

test('time pickers include all half hours and midnight as an end time', () => {
  const starts = timeOptions();
  const ends = timeOptions({ end: true });
  assert.equal(starts.length, 48);
  assert.equal(starts[0], '00:00');
  assert.equal(starts.at(-1), '23:30');
  assert.equal(ends.length, 48);
  assert.equal(ends[0], '00:30');
  assert.equal(ends.at(-1), '24:00');
});

test('suggested requests can use late-night times and roll over at midnight', () => {
  assert.deepEqual(nextRequestWindow(new Date(2026, 10, 21, 22, 55)), {
    date: '2026-11-21', start: '23:00', end: '23:30'
  });
  assert.deepEqual(nextRequestWindow(new Date(2026, 10, 21, 23, 30)), {
    date: '2026-11-22', start: '00:00', end: '00:30'
  });
  assert.deepEqual(nextRequestWindow(new Date(2026, 10, 21, 23, 59)), {
    date: '2026-11-22', start: '00:00', end: '00:30'
  });
});

test('visitor requests need name, phone, and a short message; email is optional', () => {
  const contact = validateRequestContact({
    name: '  Anh Pham ', phone: '+84 (912) 345-678', email: '', note: '  Discuss a project  '
  });
  assert.deepEqual(contact, {
    valid: true,
    value: { name: 'Anh Pham', phone: '+84 (912) 345-678', email: null, note: 'Discuss a project' }
  });

  assert.equal(validateRequestContact({ name: '', phone: '0912345678', note: 'Hello' }).valid, false);
  assert.equal(validateRequestContact({ name: 'Anh', phone: '', note: 'Hello' }).valid, false);
  assert.equal(validateRequestContact({ name: 'Anh', phone: '0912345678', note: '   ' }).valid, false);
  assert.equal(validateRequestContact({ name: 'Anh', phone: 'abc', note: 'Hello' }).valid, false);
  assert.equal(validateRequestContact({ name: 'Anh', phone: '0912345678', email: 'bad-email', note: 'Hello' }).valid, false);
});

test('optional email is normalized, and short messages are capped at 300 characters', () => {
  const contact = validateRequestContact({
    name: 'Anh', phone: '0912345678', email: '  anh@example.com ', note: 'Hello'
  });
  assert.equal(contact.valid, true);
  assert.equal(contact.value.email, 'anh@example.com');

  assert.equal(validateRequestContact({ name: 'Anh', phone: '0912345678', note: 'x'.repeat(300) }).valid, true);
  assert.equal(validateRequestContact({ name: 'Anh', phone: '0912345678', note: 'x'.repeat(301) }).valid, false);
});

test('adjacent slots do not conflict, but overlapping times do', () => {
  assert.equal(rangesOverlap('23:00', '23:30', '23:30', '24:00'), false);
  assert.equal(rangesOverlap('23:00', '24:00', '23:30', '24:00'), true);
  assert.equal(rangesOverlap('00:00', '00:30', '00:30', '01:00'), false);
});
