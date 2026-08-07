import { Box, Button, Paper, Typography } from '@mui/material';
import SearchOffIcon from '@mui/icons-material/SearchOff';
import { useLocation, useNavigate } from 'react-router-dom';

export function NotFoundPage() {
  const navigate = useNavigate();
  const location = useLocation();

  return (
    <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '60vh' }}>
      <Paper sx={{ p: 5, maxWidth: 480, textAlign: 'center' }}>
        <SearchOffIcon sx={{ fontSize: 56, color: 'text.disabled', mb: 1 }} />
        <Typography variant="h5" gutterBottom>
          Page not found
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 3, wordBreak: 'break-all' }}>
          Nothing is routed to {location.pathname}
        </Typography>
        <Button variant="contained" onClick={() => navigate('/interviews')}>
          Go to interviews
        </Button>
      </Paper>
    </Box>
  );
}
