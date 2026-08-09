import { useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  CircularProgress,
  Divider,
  IconButton,
  InputAdornment,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import PsychologyIcon from '@mui/icons-material/Psychology';
import Visibility from '@mui/icons-material/Visibility';
import VisibilityOff from '@mui/icons-material/VisibilityOff';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { describeError } from '../api/client';
import { useAuth } from '../auth/AuthContext';
import { config, isProduction } from '../config';

/** Seed accounts, shown only outside production so a trainee can get in without reading the docs. */
const DEMO_ACCOUNTS = [
  { label: 'Administrator', email: 'admin@aiinterview.local', password: 'Admin@12345' },
  { label: 'Interviewer', email: 'priya.sharma@aiinterview.local', password: 'Interviewer@12345' },
  { label: 'Candidate', email: 'neha.gupta@example.com', password: 'Candidate@12345' },
];

export function LoginPage() {
  const { login, isAuthenticated, initialising } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  // Where the user was heading before the guard redirected them here.
  const redirectTo = location.state?.from?.pathname || '/interviews';

  if (isAuthenticated && !initialising) {
    return <Navigate to={redirectTo} replace />;
  }

  const handleSubmit = async (event) => {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const user = await login(email.trim(), password);
      // A candidate has no dashboard, so send them straight to their schedule.
      const destination = user.role === 'CANDIDATE' ? '/interviews' : redirectTo;
      navigate(destination, { replace: true });
    } catch (caught) {
      setError(describeError(caught, 'Sign in failed. Check your email and password.'));
    } finally {
      setSubmitting(false);
    }
  };

  // Not named `useDemoAccount`: the `use` prefix is reserved for Hooks, and a plain event handler
  // carrying it trips the rules-of-hooks lint (correctly, since it is called from a callback).
  const fillDemoAccount = (account) => {
    setEmail(account.email);
    setPassword(account.password);
    setError(null);
  };

  return (
    <Box
      sx={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        p: 2,
        background: 'linear-gradient(135deg, #0b3d91 0%, #00796b 100%)',
      }}
    >
      <Card sx={{ width: '100%', maxWidth: 440 }}>
        <CardContent sx={{ p: 4 }}>
          <Stack alignItems="center" spacing={1} sx={{ mb: 3 }}>
            <PsychologyIcon color="primary" sx={{ fontSize: 44 }} />
            <Typography variant="h5" component="h1">
              AI Interview Platform
            </Typography>
            <Typography variant="body2" color="text.secondary">
              Login in to continue with the interview.
            </Typography>
          </Stack>

          {error ? (
            <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
              {error}
            </Alert>
          ) : null}

          <Box component="form" onSubmit={handleSubmit} noValidate>
            <Stack spacing={2}>
              <TextField
                label="Email"
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                required
                fullWidth
                autoComplete="username"
                autoFocus
                size="medium"
                inputProps={{ 'aria-label': 'Email address' }}
              />
              <TextField
                label="Password"
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                required
                fullWidth
                autoComplete="current-password"
                size="medium"
                InputProps={{
                  endAdornment: (
                    <InputAdornment position="end">
                      <IconButton
                        onClick={() => setShowPassword((visible) => !visible)}
                        edge="end"
                        aria-label={showPassword ? 'Hide password' : 'Show password'}
                      >
                        {showPassword ? <VisibilityOff /> : <Visibility />}
                      </IconButton>
                    </InputAdornment>
                  ),
                }}
              />
              <Button
                type="submit"
                variant="contained"
                size="large"
                fullWidth
                disabled={submitting || !email || !password}
                startIcon={submitting ? <CircularProgress size={18} color="inherit" /> : null}
              >
                {submitting ? 'Signing in…' : 'Sign in'}
              </Button>
            </Stack>
          </Box>

          {!isProduction ? (
            <>
              <Divider sx={{ my: 3 }}>
                <Typography variant="caption" color="text.secondary">
                  Seed accounts ({config.appEnv})
                </Typography>
              </Divider>
              <Stack spacing={1}>
                {DEMO_ACCOUNTS.map((account) => (
                  <Button
                    key={account.email}
                    size="small"
                    variant="outlined"
                    onClick={() => fillDemoAccount(account)}
                    fullWidth
                  >
                    {account.label} — {account.email}
                  </Button>
                ))}
              </Stack>
            </>
          ) : null}
        </CardContent>
      </Card>
    </Box>
  );
}
