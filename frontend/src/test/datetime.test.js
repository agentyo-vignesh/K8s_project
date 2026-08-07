import { describe, expect, it } from 'vitest';
import {
  formatDate,
  formatDateTime,
  fromDateTimeLocalValue,
  isFuture,
  toDateTimeLocalValue,
} from '../utils/datetime';

/**
 * The timezone conversions are the part worth testing: getting them wrong shows an interviewer the
 * wrong meeting time, and the bug is invisible for anyone running in UTC.
 */
describe('datetime helpers', () => {
  it('renders an em dash for a missing value rather than "Invalid Date"', () => {
    expect(formatDateTime(null)).toBe('—');
    expect(formatDateTime('')).toBe('—');
    expect(formatDate(undefined)).toBe('—');
  });

  it('renders an em dash for an unparseable value', () => {
    expect(formatDateTime('not-a-date')).toBe('—');
  });

  it('round-trips through the datetime-local representation', () => {
    const original = '2026-08-12T09:30:00Z';
    const localValue = toDateTimeLocalValue(original);

    // The local string has no timezone, so it must not carry a Z or an offset.
    expect(localValue).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/);
    expect(localValue).not.toContain('Z');

    // Converting back must land on the same instant.
    expect(new Date(fromDateTimeLocalValue(localValue)).getTime()).toBe(new Date(original).getTime());
  });

  it('treats a datetime-local value as local wall-clock time', () => {
    const isoString = fromDateTimeLocalValue('2026-08-12T09:30');
    const parsed = new Date(isoString);

    expect(parsed.getHours()).toBe(9);
    expect(parsed.getMinutes()).toBe(30);
  });

  it('returns null for an empty datetime-local value', () => {
    expect(fromDateTimeLocalValue('')).toBeNull();
    expect(fromDateTimeLocalValue(null)).toBeNull();
  });

  it('detects whether an instant is in the future', () => {
    const future = new Date(Date.now() + 86_400_000).toISOString();
    const past = new Date(Date.now() - 86_400_000).toISOString();

    expect(isFuture(future)).toBe(true);
    expect(isFuture(past)).toBe(false);
    expect(isFuture(null)).toBe(false);
  });
});
