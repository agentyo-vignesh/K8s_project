/**
 * Date handling.
 *
 * The API speaks UTC ISO-8601 (`Instant`). The browser shows and collects local time. Every
 * conversion between the two lives here, because scattering `new Date(...)` through the pages is how
 * an interview scheduled for 09:30 ends up displayed at 04:00.
 */
import { format, formatDistanceToNowStrict, isValid, parseISO } from 'date-fns';

/** Formats an ISO instant for display in the viewer's local timezone. */
export function formatDateTime(isoString, pattern = 'dd MMM yyyy, HH:mm') {
  if (!isoString) return '—';
  const parsed = parseISO(isoString);
  return isValid(parsed) ? format(parsed, pattern) : '—';
}

export function formatDate(isoString) {
  return formatDateTime(isoString, 'dd MMM yyyy');
}

/** "in 3 days" / "2 hours ago", for schedule context at a glance. */
export function formatRelative(isoString) {
  if (!isoString) return '';
  const parsed = parseISO(isoString);
  if (!isValid(parsed)) return '';
  const suffix = parsed.getTime() > Date.now() ? 'from now' : 'ago';
  return `${formatDistanceToNowStrict(parsed)} ${suffix}`;
}

/**
 * ISO instant -> the value a `datetime-local` input expects.
 *
 * `datetime-local` has no timezone, so the value must be local wall-clock time. Slicing the ISO
 * string would show the UTC time in a local-time field, which is exactly the bug this avoids.
 */
export function toDateTimeLocalValue(isoString) {
  if (!isoString) return '';
  const parsed = parseISO(isoString);
  return isValid(parsed) ? format(parsed, "yyyy-MM-dd'T'HH:mm") : '';
}

/** `datetime-local` value -> ISO instant in UTC. */
export function fromDateTimeLocalValue(localValue) {
  if (!localValue) return null;
  // `new Date('YYYY-MM-DDTHH:mm')` is interpreted as local time, which is what the input means.
  const parsed = new Date(localValue);
  return isValid(parsed) ? parsed.toISOString() : null;
}

/** Default for a new interview: tomorrow at 10:00 local, rounded to the minute. */
export function defaultScheduledAt() {
  const tomorrow = new Date();
  tomorrow.setDate(tomorrow.getDate() + 1);
  tomorrow.setHours(10, 0, 0, 0);
  return format(tomorrow, "yyyy-MM-dd'T'HH:mm");
}

export function isFuture(isoString) {
  if (!isoString) return false;
  const parsed = parseISO(isoString);
  return isValid(parsed) && parsed.getTime() > Date.now();
}
