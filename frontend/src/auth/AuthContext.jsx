/**
 * Authentication state.
 *
 * Tokens and the user are mirrored in localStorage so a page refresh does not force a re-login. The
 * stored user is trusted for *rendering* decisions only (which nav items to show); every actual
 * authorization check happens server-side, so editing localStorage buys nothing but a UI that offers
 * buttons the API will refuse.
 */
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { setAuthenticationLostHandler, tokenStorage } from '../api/client';
import { authApi } from '../api/endpoints';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [user, setUser] = useState(() => tokenStorage.getUser());
  const [initialising, setInitialising] = useState(() => Boolean(tokenStorage.getAccessToken()));

  const logout = useCallback(async () => {
    const refreshToken = tokenStorage.getRefreshToken();
    try {
      if (tokenStorage.getAccessToken()) {
        // Server-side revocation, so the token cannot be replayed if it was captured. A failure here
        // must not block the client-side logout.
        await authApi.logout(refreshToken);
      }
    } catch {
      // Already expired or the server is unreachable: clearing locally is still correct.
    } finally {
      tokenStorage.clear();
      setUser(null);
    }
  }, []);

  // Registered once so the Axios interceptor can drop state when a refresh fails, without importing
  // React state or the router.
  useEffect(() => {
    setAuthenticationLostHandler(() => setUser(null));
  }, []);

  // On boot with a stored token, confirm it is still valid. A revoked or expired token would
  // otherwise leave the UI rendering a logged-in shell whose every request 401s.
  useEffect(() => {
    let cancelled = false;

    async function verifyStoredSession() {
      if (!tokenStorage.getAccessToken()) {
        setInitialising(false);
        return;
      }
      try {
        const { data } = await authApi.me();
        if (!cancelled) {
          tokenStorage.setUser(data);
          setUser(data);
        }
      } catch {
        if (!cancelled) {
          tokenStorage.clear();
          setUser(null);
        }
      } finally {
        if (!cancelled) {
          setInitialising(false);
        }
      }
    }

    verifyStoredSession();
    return () => {
      cancelled = true;
    };
  }, []);

  const login = useCallback(async (email, password) => {
    const { data } = await authApi.login(email, password);
    tokenStorage.setTokens(data.accessToken, data.refreshToken);
    tokenStorage.setUser(data.user);
    setUser(data.user);
    return data.user;
  }, []);

  const value = useMemo(
    () => ({
      user,
      initialising,
      isAuthenticated: Boolean(user),
      login,
      logout,
      hasRole: (...roles) => Boolean(user) && roles.includes(user.role),
      /** Convenience for the many places that gate on "can change things". */
      canManage: Boolean(user) && ['ADMIN', 'INTERVIEWER'].includes(user.role),
      isAdmin: user?.role === 'ADMIN',
    }),
    [user, initialising, login, logout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used inside an AuthProvider');
  }
  return context;
}
