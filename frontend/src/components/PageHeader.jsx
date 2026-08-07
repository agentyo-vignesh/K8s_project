import { Box, Button, Stack, Typography } from '@mui/material';
import ArrowBackIcon from '@mui/icons-material/ArrowBack';
import { useNavigate } from 'react-router-dom';

/** Page title, optional description, an optional back button and a slot for actions. */
export function PageHeader({ title, description, backTo, actions }) {
  const navigate = useNavigate();

  return (
    <Box sx={{ mb: 3 }}>
      {backTo ? (
        <Button
          size="small"
          startIcon={<ArrowBackIcon />}
          onClick={() => navigate(backTo)}
          sx={{ mb: 1, ml: -1 }}
        >
          Back
        </Button>
      ) : null}
      <Stack
        direction={{ xs: 'column', sm: 'row' }}
        justifyContent="space-between"
        alignItems={{ xs: 'flex-start', sm: 'center' }}
        spacing={2}
      >
        <Box sx={{ minWidth: 0 }}>
          <Typography variant="h5" component="h1" noWrap={false}>
            {title}
          </Typography>
          {description ? (
            <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5 }}>
              {description}
            </Typography>
          ) : null}
        </Box>
        {actions ? <Stack direction="row" spacing={1}>{actions}</Stack> : null}
      </Stack>
    </Box>
  );
}
