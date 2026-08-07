/**
 * Application-wide toasts.
 *
 * Centralised so an error message is presented the same way everywhere, and so the server's request
 * id can be shown alongside a failure: that id is the only thing that connects what the user saw to
 * the log line that explains it.
 */
import { Alert, Snackbar, Typography } from '@mui/material';
import { createContext, useCallback, useContext, useMemo, useState } from 'react';
import { describeError, requestIdOf } from '../api/client';

const NotificationContext = createContext(null);

export function NotificationProvider({ children }) {
  const [notification, setNotification] = useState(null);

  const close = useCallback(() => setNotification(null), []);

  const value = useMemo(
    () => ({
      notifySuccess: (message) => setNotification({ severity: 'success', message }),
      notifyInfo: (message) => setNotification({ severity: 'info', message }),
      notifyWarning: (message) => setNotification({ severity: 'warning', message }),

      /** Renders an Axios error using the server's own message plus its request id. */
      notifyError: (error, fallback) =>
        setNotification({
          severity: 'error',
          message: describeError(error, fallback),
          requestId: requestIdOf(error),
        }),

      notifyMessage: (message) => setNotification({ severity: 'error', message }),
    }),
    [],
  );

  return (
    <NotificationContext.Provider value={value}>
      {children}
      <Snackbar
        open={Boolean(notification)}
        autoHideDuration={notification?.severity === 'error' ? 10000 : 4000}
        onClose={close}
        anchorOrigin={{ vertical: 'bottom', horizontal: 'center' }}
      >
        {notification ? (
          <Alert severity={notification.severity} onClose={close} variant="filled" sx={{ maxWidth: 560 }}>
            {notification.message}
            {notification.requestId ? (
              <Typography variant="caption" component="div" sx={{ mt: 0.5, opacity: 0.85 }}>
                Request id: {notification.requestId}
              </Typography>
            ) : null}
          </Alert>
        ) : null}
      </Snackbar>
    </NotificationContext.Provider>
  );
}

export function useNotifications() {
  const context = useContext(NotificationContext);
  if (!context) {
    throw new Error('useNotifications must be used inside a NotificationProvider');
  }
  return context;
}
