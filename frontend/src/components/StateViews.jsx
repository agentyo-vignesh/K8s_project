/**
 * Loading, empty and error placeholders.
 *
 * Shared so every list distinguishes the three states that are easy to conflate: still loading,
 * loaded-and-genuinely-empty, and failed. Rendering "No results" for a failed request is the single
 * most common way a UI hides an outage from its user.
 */
import { Box, Button, CircularProgress, Paper, Typography } from '@mui/material';
import ErrorOutlineIcon from '@mui/icons-material/ErrorOutline';
import InboxIcon from '@mui/icons-material/Inbox';
import RefreshIcon from '@mui/icons-material/Refresh';

export function LoadingState({ label = 'Loading…', minHeight = 240 }) {
  return (
    <Box
      sx={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', minHeight, gap: 2 }}
      role="status"
      aria-live="polite"
    >
      <CircularProgress />
      <Typography variant="body2" color="text.secondary">
        {label}
      </Typography>
    </Box>
  );
}

export function EmptyState({ title, description, action }) {
  return (
    <Paper sx={{ p: 5, textAlign: 'center' }}>
      <InboxIcon sx={{ fontSize: 44, color: 'text.disabled', mb: 1 }} />
      <Typography variant="h6" gutterBottom>
        {title}
      </Typography>
      {description ? (
        <Typography variant="body2" color="text.secondary" sx={{ mb: action ? 2 : 0 }}>
          {description}
        </Typography>
      ) : null}
      {action}
    </Paper>
  );
}

export function ErrorState({ message, requestId, onRetry }) {
  return (
    <Paper sx={{ p: 5, textAlign: 'center' }}>
      <ErrorOutlineIcon color="error" sx={{ fontSize: 44, mb: 1 }} />
      <Typography variant="h6" gutterBottom>
        Could not load this page
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        {message}
      </Typography>
      {requestId ? (
        <Typography variant="caption" color="text.disabled" display="block" sx={{ mb: 2 }}>
          Request id: {requestId}
        </Typography>
      ) : null}
      {onRetry ? (
        <Button variant="outlined" startIcon={<RefreshIcon />} onClick={onRetry}>
          Try again
        </Button>
      ) : null}
    </Paper>
  );
}
