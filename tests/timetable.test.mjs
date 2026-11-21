import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DAY_END_MINUTE,
  DAY_START_MINUTE,
  draggedMinuteRange,
  formatScheduleTimestamp,
  isPastDate,
  monthCalendarDates,
  nextRequestWindow,
  rangesOverlap,
  timeMinutes,
  timePickerHours,
  timePickerMinutes,
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

test('only dates before today are marked as past', () => {
  assert.equal(isPastDate('2026-11-20', '2026-11-21'), true);
  assert.equal(isPastDate('2026-11-21', '2026-11-21'), false);
  assert.equal(isPastDate('2026-11-22', '2026-11-21'), false);
});

test('time ranges reject invalid clocks, empty durations, and 24:00 starts', () => {
  assert.equal(validateTimeRange('24:00', '24:00'), false);
  assert.equal(validateTimeRange('23:30', '23:30'), false);
  assert.equal(validateTimeRange('23:30', '00:00'), false);
  assert.equal(validateTimeRange('24:30', '25:00'), false);
  assert.equal(validateTimeRange('08:15', '09:00'), true);
});

test('time pickers allow every minute, with 24:00 only as an end time', () => {
  const startHours = timePickerHours();
  const endHours = timePickerHours({ end: true });
  const minutes = timePickerMinutes();
  assert.equal(startHours.length, 24);
  assert.equal(startHours[0], '00');
  assert.equal(startHours.at(-1), '23');
  assert.equal(endHours.length, 25);
  assert.equal(endHours.at(-1), '24');
  assert.equal(minutes.length, 60);
  assert.equal(minutes[0], '00');
  assert.equal(minutes.at(-1), '59');
  assert.equal(validateTimeRange('16:01', '16:02'), true);
  assert.equal(validateTimeRange('23:59', '24:00'), true);
});

test('dragged ranges work in either direction and stop at the day boundary', () => {
  assert.deepEqual(draggedMinuteRange(600, 615), { start: 600, end: 615 });
  assert.deepEqual(draggedMinuteRange(615, 600), { start: 600, end: 615 });
  assert.deepEqual(draggedMinuteRange(600, 600), { start: 600, end: 601 });
  assert.deepEqual(draggedMinuteRange(1439, 1440), { start: 1439, end: 1440 });
  assert.deepEqual(draggedMinuteRange(1439, 2000), { start: 1439, end: 1440 });
});

test('full timestamps use the requested GMT+7 wall-clock format, including midnight rollover', () => {
  assert.equal(formatScheduleTimestamp('2026-11-21', '16:01'), 'Sat 21 Nov 16:01:00 GMT+7');
  assert.equal(formatScheduleTimestamp('2026-11-21', '24:00'), 'Sun 22 Nov 00:00:00 GMT+7');
});

test('date picker months align Monday first and include leap days', () => {
  const november = monthCalendarDates(2026, 11);
  assert.equal(november[0], '2026-10-26');
  assert.equal(november[6], '2026-11-01');
  assert.equal(november.at(-1), '2026-12-06');
  const february = monthCalendarDates(2024, 2);
  assert.equal(february.includes('2024-02-29'), true);
  assert.equal(february.length % 7, 0);
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
