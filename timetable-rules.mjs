export const DAY_START_MINUTE = 0;
export const DAY_END_MINUTE = 24 * 60;
export const MAX_SHORT_MESSAGE_LENGTH = 300;

export function timeMinutes(value) {
  const match = /^(\d{2}):(\d{2})$/.exec(String(value ?? ''));
  if (!match) return Number.NaN;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (minute > 59 || hour > 24 || (hour === 24 && minute !== 0)) return Number.NaN;
  return hour * 60 + minute;
}

export function validateTimeRange(start, end) {
  const startMinute = timeMinutes(start);
  const endMinute = timeMinutes(end);
  return Number.isFinite(startMinute) && Number.isFinite(endMinute)
    && startMinute >= DAY_START_MINUTE && startMinute < DAY_END_MINUTE
    && endMinute > startMinute && endMinute <= DAY_END_MINUTE;
}

export function validateRequestContact({ name, phone, email, note } = {}) {
  const cleanName = String(name ?? '').trim();
  const cleanPhone = String(phone ?? '').trim();
  const cleanEmail = String(email ?? '').trim();
  const cleanNote = String(note ?? '').trim();

  if (cleanName.length < 1 || cleanName.length > 60) {
    return { valid: false, error: 'Enter your name (up to 60 characters).' };
  }
  if (cleanPhone.length < 7 || cleanPhone.length > 32 || !/^[+]?[0-9][0-9\s().-]{6,30}$/.test(cleanPhone)) {
    return { valid: false, error: 'Enter a valid phone number.' };
  }
  if (cleanEmail && (cleanEmail.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail))) {
    return { valid: false, error: 'Enter a valid email address or leave it blank.' };
  }
  if (cleanNote.length < 1 || cleanNote.length > MAX_SHORT_MESSAGE_LENGTH) {
    return { valid: false, error: `Add a short message (up to ${MAX_SHORT_MESSAGE_LENGTH} characters).` };
  }
  return { valid: true, value: { name: cleanName, phone: cleanPhone, email: cleanEmail || null, note: cleanNote } };
}

export function rangesOverlap(aStart, aEnd, bStart, bEnd) {
  return timeMinutes(aStart) < timeMinutes(bEnd) && timeMinutes(aEnd) > timeMinutes(bStart);
}

function formatMinute(minute) {
  return `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;
}

export function nextRequestWindow(now = new Date()) {
  const date = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
  let startMinute = Math.ceil((now.getHours() * 60 + now.getMinutes() + 1) / 30) * 30;
  if (startMinute >= DAY_END_MINUTE) {
    date.setDate(date.getDate() + 1);
    startMinute = DAY_START_MINUTE;
  }
  const endMinute = Math.min(startMinute + 30, DAY_END_MINUTE);
  const pad = value => String(value).padStart(2, '0');
  return {
    date: `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`,
    start: formatMinute(startMinute),
    end: formatMinute(endMinute)
  };
}

export function timeOptions({ end = false } = {}) {
  const values = [];
  const first = end ? 30 : 0;
  const last = end ? DAY_END_MINUTE : DAY_END_MINUTE - 30;
  for (let minute = first; minute <= last; minute += 30) values.push(formatMinute(minute));
  return values;
}
