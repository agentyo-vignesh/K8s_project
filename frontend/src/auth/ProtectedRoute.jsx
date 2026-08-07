/**
 * Route guard.
 *
 * A UI convenience, not a security boundary: it decides what to render, while the API decides what is
 * permitted. Both exist because showing a candidate an admin screen that then 403s is a bad
 * experience, not because the client can be trusted.
 */
import { Box, CircularProgress } from '@mui/material';
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from './AuthContext';

export function ProtectedRoute({ roles }) {
  const { isAuthenticated, initialising, user } = useAuth();
  const location = useLocation();

  // Redirecting while the stored token is still being verified would bounce a logged-in user to the
  // login page on every refresh.
  if (initialising) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center', minHeight: '60vh' }}>
        <CircularProgress aria-label="Restoring your session" />
      </Box>
    );
  }

  if (!isAuthenticated) {
    // `state.from` lets the login page return the user to where they were heading.
    return <Navigate to="/login" replace state={{ from: location }} />;
  }

  if (roles && roles.length > 0 && !roles.includes(user.role)) {
    return <Navigate to="/forbidden" replace />;
  }

  return <Outlet />;
}
