import { Box, Button, Paper, Stack, Typography } from '@mui/material';
import BlockIcon from '@mui/icons-material/Block';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';

/** Shown when the route guard refuses a role, so the user gets an explanation rather than a blank 403. */
export function ForbiddenPage() {
  const navigate = useNavigate();
  const { user } = useAuth();

  return (
    <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '70vh', p: 2 }}>
      <Paper sx={{ p: 5, maxWidth: 480, textAlign: 'center' }}>
        <BlockIcon color="error" sx={{ fontSize: 56, mb: 1 }} />
        <Typography variant="h5" gutterBottom>
          Not available for your role
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
          {user
            ? `Your account has the ${user.role} role, which does not have access to this page.`
            : 'You need to sign in to view this page.'}
        </Typography>
        <Stack direction="row" spacing={1} justifyContent="center">
          <Button variant="contained" onClick={() => navigate('/interviews')}>
            Go to interviews
          </Button>
          {!user ? <Button onClick={() => navigate('/login')}>Sign in</Button> : null}
        </Stack>
      </Paper>
    </Box>
  );
}
