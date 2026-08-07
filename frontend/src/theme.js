import { createTheme } from '@mui/material/styles';

/**
 * Application theme.
 *
 * Status colours are defined once here and consumed by every chip and badge, so a status means the
 * same colour on the dashboard, the candidate list and the interview detail page.
 */
export const theme = createTheme({
  palette: {
    mode: 'light',
    primary: { main: '#0b3d91', light: '#3d63b0', dark: '#062a68', contrastText: '#ffffff' },
    secondary: { main: '#00796b', light: '#4aa89a', dark: '#004c40', contrastText: '#ffffff' },
    background: { default: '#f4f6f9', paper: '#ffffff' },
    success: { main: '#2e7d32' },
    warning: { main: '#ed6c02' },
    error: { main: '#c62828' },
    info: { main: '#0277bd' },
  },

  shape: { borderRadius: 8 },

  typography: {
    fontFamily: [
      '"Segoe UI"',
      'Roboto',
      '-apple-system',
      'BlinkMacSystemFont',
      'Helvetica Neue',
      'Arial',
      'sans-serif',
    ].join(','),
    h4: { fontWeight: 600 },
    h5: { fontWeight: 600 },
    h6: { fontWeight: 600 },
    button: { textTransform: 'none', fontWeight: 600 },
  },

  components: {
    MuiPaper: { defaultProps: { elevation: 0 }, styleOverrides: { root: { border: '1px solid #e3e7ee' } } },
    MuiButton: { defaultProps: { disableElevation: true } },
    MuiTableCell: { styleOverrides: { head: { fontWeight: 600, backgroundColor: '#eef1f6' } } },
    MuiTextField: { defaultProps: { size: 'small' } },
    MuiSelect: { defaultProps: { size: 'small' } },
  },
});

/** MUI colour for each candidate status. */
export const candidateStatusColor = {
  NEW: 'default',
  SCREENING: 'info',
  INTERVIEWING: 'primary',
  OFFERED: 'secondary',
  HIRED: 'success',
  REJECTED: 'error',
  ON_HOLD: 'warning',
};

/** MUI colour for each interview status. */
export const interviewStatusColor = {
  SCHEDULED: 'info',
  IN_PROGRESS: 'warning',
  COMPLETED: 'success',
  CANCELLED: 'default',
};

/** MUI colour for each hiring recommendation. */
export const recommendationColor = {
  STRONG_HIRE: 'success',
  HIRE: 'primary',
  HOLD: 'warning',
  NO_HIRE: 'error',
};

/** MUI colour for each question difficulty. */
export const difficultyColor = {
  EASY: 'success',
  MEDIUM: 'warning',
  HARD: 'error',
};
