import { describe, expect, it } from 'vitest';
import { describeError, requestIdOf, tokenStorage } from '../api/client';
import { humanise } from '../components/StatusChip';

describe('describeError', () => {
  it('prefers the field errors the server reported', () => {
    const error = {
      response: {
        data: {
          fieldErrors: [
            { field: 'email', message: 'must be a well-formed email address' },
            { field: 'primarySkill', message: 'is required' },
          ],
        },
      },
    };

    expect(describeError(error)).toBe(
      'email: must be a well-formed email address; primarySkill: is required',
    );
  });

  it('falls back to the server message', () => {
    const error = { response: { data: { message: 'Candidate already exists with email a@b.c' } } };

    expect(describeError(error)).toBe('Candidate already exists with email a@b.c');
  });

  it('explains an HTML reply as routing rather than a server fault', () => {
    // nginx answers an unrouted /api with index.html and status 200, so the
    // message has to point at routing, not at the middleware being down.
    const message = describeError({ isHtmlResponse: true });
    expect(message).toMatch(/web page instead of data/);
    expect(message).toMatch(/\/api/);
  });

  it('explains a timeout in terms the user can act on', () => {
    expect(describeError({ code: 'ECONNABORTED' })).toContain('timed out');
  });

  it('distinguishes an unreachable server from a server error', () => {
    // No `response` means the request never got an answer, which is a different problem from a 500.
    expect(describeError({ message: 'Network Error' })).toContain('Cannot reach the server');
  });

  it('uses the supplied fallback when the server said nothing useful', () => {
    const error = { response: { status: 500, data: {} } };

    expect(describeError(error, 'Could not save.')).toBe('Could not save.');
  });
});

describe('requestIdOf', () => {
  it('reads the id from the error body', () => {
    expect(requestIdOf({ response: { data: { requestId: 'abc-123' } } })).toBe('abc-123');
  });

  it('falls back to the response header', () => {
    expect(requestIdOf({ response: { data: {}, headers: { 'x-request-id': 'hdr-9' } } })).toBe('hdr-9');
  });

  it('returns null when there is nothing to correlate with', () => {
    expect(requestIdOf(undefined)).toBeNull();
  });
});

describe('tokenStorage', () => {
  it('survives a corrupt stored user without throwing', () => {
    // A corrupt entry must not break application boot.
    localStorage.setItem('aip.user', '{not-json');

    expect(tokenStorage.getUser()).toBeNull();
  });

  it('round-trips tokens and the user', () => {
    tokenStorage.setTokens('access-1', 'refresh-1');
    tokenStorage.setUser({ email: 'a@b.c', role: 'ADMIN' });

    expect(tokenStorage.getAccessToken()).toBe('access-1');
    expect(tokenStorage.getRefreshToken()).toBe('refresh-1');
    expect(tokenStorage.getUser().role).toBe('ADMIN');

    tokenStorage.clear();
    expect(tokenStorage.getAccessToken()).toBeNull();
    expect(tokenStorage.getUser()).toBeNull();
  });

  it('keeps the existing refresh token when only an access token is supplied', () => {
    tokenStorage.setTokens('access-1', 'refresh-1');
    tokenStorage.setTokens('access-2');

    expect(tokenStorage.getAccessToken()).toBe('access-2');
    expect(tokenStorage.getRefreshToken()).toBe('refresh-1');
  });
});

describe('humanise', () => {
  it('turns an enum constant into a readable label', () => {
    expect(humanise('IN_PROGRESS')).toBe('In progress');
    expect(humanise('STRONG_HIRE')).toBe('Strong hire');
    expect(humanise('NEW')).toBe('New');
  });

  it('returns an empty string for a missing value', () => {
    expect(humanise(null)).toBe('');
  });
});
