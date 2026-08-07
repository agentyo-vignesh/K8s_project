import { useEffect, useState } from 'react';
import {
  Box,
  Button,
  CircularProgress,
  MenuItem,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import SaveIcon from '@mui/icons-material/Save';
import { useNavigate, useParams } from 'react-router-dom';
import { candidateApi } from '../api/endpoints';
import { useNotifications } from '../components/NotificationProvider';
import { PageHeader } from '../components/PageHeader';
import { ErrorState, LoadingState } from '../components/StateViews';
import { useApiResource } from '../hooks/useApiResource';

const STATUS_OPTIONS = ['NEW', 'SCREENING', 'INTERVIEWING', 'OFFERED', 'HIRED', 'REJECTED', 'ON_HOLD'];

const EMPTY_FORM = {
  firstName: '',
  lastName: '',
  email: '',
  phone: '',
  currentCompany: '',
  currentPosition: '',
  yearsOfExperience: '0',
  primarySkill: '',
  location: '',
  status: 'NEW',
  notes: '',
};

/**
 * Client-side validation.
 *
 * Deliberately a mirror of the server's Bean Validation rules, not a replacement: it gives immediate
 * feedback, while the API remains the authority. Any rule that only exists here would be trivially
 * bypassable.
 */
function validate(form) {
  const errors = {};
  if (!form.firstName.trim()) errors.firstName = 'First name is required';
  if (!form.lastName.trim()) errors.lastName = 'Last name is required';
  if (!form.email.trim()) {
    errors.email = 'Email is required';
  } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.email.trim())) {
    errors.email = 'Enter a valid email address';
  }
  if (!form.primarySkill.trim()) errors.primarySkill = 'Primary skill is required';

  const years = Number(form.yearsOfExperience);
  if (Number.isNaN(years)) {
    errors.yearsOfExperience = 'Enter a number';
  } else if (years < 0 || years > 60) {
    errors.yearsOfExperience = 'Must be between 0 and 60';
  }

  // Hyphen last in the class so it is a literal, with no backslash to escape it.
  if (form.phone && !/^[+0-9][0-9 ()-]{6,29}$/.test(form.phone.trim())) {
    errors.phone = 'Digits, spaces, parentheses and hyphens only';
  }
  return errors;
}

export function CandidateFormPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { notifySuccess, notifyError } = useNotifications();
  const isEdit = Boolean(id);

  const [form, setForm] = useState(EMPTY_FORM);
  const [errors, setErrors] = useState({});
  const [submitting, setSubmitting] = useState(false);

  const { data, loading, error, reload } = useApiResource(
    () => candidateApi.findById(id),
    [id],
    { skip: !isEdit },
  );

  // Populate the form once the existing candidate arrives. Nullish fields become empty strings so
  // the inputs stay controlled; React warns and misbehaves if a value flips between null and string.
  useEffect(() => {
    if (!data) return;
    setForm({
      firstName: data.firstName || '',
      lastName: data.lastName || '',
      email: data.email || '',
      phone: data.phone || '',
      currentCompany: data.currentCompany || '',
      currentPosition: data.currentPosition || '',
      yearsOfExperience: String(data.yearsOfExperience ?? '0'),
      primarySkill: data.primarySkill || '',
      location: data.location || '',
      status: data.status || 'NEW',
      notes: data.notes || '',
    });
  }, [data]);

  const setField = (field) => (event) => {
    setForm((current) => ({ ...current, [field]: event.target.value }));
    setErrors((current) => ({ ...current, [field]: undefined }));
  };

  const handleSubmit = async (event) => {
    event.preventDefault();
    const validationErrors = validate(form);
    if (Object.keys(validationErrors).length > 0) {
      setErrors(validationErrors);
      return;
    }

    const payload = {
      ...form,
      firstName: form.firstName.trim(),
      lastName: form.lastName.trim(),
      email: form.email.trim(),
      primarySkill: form.primarySkill.trim(),
      yearsOfExperience: Number(form.yearsOfExperience),
      // Blank optional fields are sent as null rather than "", so the column stays NULL instead of
      // holding an empty string that then has to be special-cased on read.
      phone: form.phone.trim() || null,
      currentCompany: form.currentCompany.trim() || null,
      currentPosition: form.currentPosition.trim() || null,
      location: form.location.trim() || null,
      notes: form.notes.trim() || null,
    };

    setSubmitting(true);
    try {
      if (isEdit) {
        await candidateApi.update(id, payload);
        notifySuccess('Candidate updated.');
        navigate(`/candidates/${id}`);
      } else {
        const { data: created } = await candidateApi.create(payload);
        notifySuccess('Candidate created.');
        navigate(`/candidates/${created.id}`);
      }
    } catch (caught) {
      // Field-level failures the server found (a duplicate email, for instance) are surfaced as a
      // toast; the server's message is more specific than anything guessable here.
      notifyError(caught, 'Could not save this candidate.');
    } finally {
      setSubmitting(false);
    }
  };

  if (isEdit && loading && !data) {
    return <LoadingState label="Loading candidate…" />;
  }
  if (isEdit && error && !data) {
    return <ErrorState message={error.message} requestId={error.requestId} onRetry={reload} />;
  }

  return (
    <Box>
      <PageHeader
        title={isEdit ? `Edit ${data?.fullName || 'candidate'}` : 'New candidate'}
        description={isEdit ? 'Update the candidate record.' : 'Add a candidate to the pipeline.'}
        backTo={isEdit ? `/candidates/${id}` : '/candidates'}
      />

      <Paper sx={{ p: 3, maxWidth: 900 }}>
        <Box component="form" onSubmit={handleSubmit} noValidate>
          <Typography variant="subtitle2" color="text.secondary" gutterBottom>
            Identity
          </Typography>
          <Box sx={{ display: 'grid', gap: 2, gridTemplateColumns: { xs: '1fr', sm: '1fr 1fr' }, mb: 3 }}>
            <TextField
              label="First name"
              value={form.firstName}
              onChange={setField('firstName')}
              error={Boolean(errors.firstName)}
              helperText={errors.firstName}
              required
              inputProps={{ maxLength: 80 }}
            />
            <TextField
              label="Last name"
              value={form.lastName}
              onChange={setField('lastName')}
              error={Boolean(errors.lastName)}
              helperText={errors.lastName}
              required
              inputProps={{ maxLength: 80 }}
            />
            <TextField
              label="Email"
              type="email"
              value={form.email}
              onChange={setField('email')}
              error={Boolean(errors.email)}
              helperText={errors.email || 'Must be unique across candidates'}
              required
              inputProps={{ maxLength: 255 }}
            />
            <TextField
              label="Phone"
              value={form.phone}
              onChange={setField('phone')}
              error={Boolean(errors.phone)}
              helperText={errors.phone}
              inputProps={{ maxLength: 30 }}
            />
          </Box>

          <Typography variant="subtitle2" color="text.secondary" gutterBottom>
            Professional
          </Typography>
          <Box sx={{ display: 'grid', gap: 2, gridTemplateColumns: { xs: '1fr', sm: '1fr 1fr' }, mb: 3 }}>
            <TextField
              label="Primary skill"
              value={form.primarySkill}
              onChange={setField('primarySkill')}
              error={Boolean(errors.primarySkill)}
              helperText={errors.primarySkill || 'e.g. Kubernetes, Java, Terraform'}
              required
              inputProps={{ maxLength: 100 }}
            />
            <TextField
              label="Years of experience"
              type="number"
              value={form.yearsOfExperience}
              onChange={setField('yearsOfExperience')}
              error={Boolean(errors.yearsOfExperience)}
              helperText={errors.yearsOfExperience}
              required
              inputProps={{ min: 0, max: 60, step: 0.5 }}
            />
            <TextField
              label="Current company"
              value={form.currentCompany}
              onChange={setField('currentCompany')}
              inputProps={{ maxLength: 150 }}
            />
            <TextField
              label="Current position"
              value={form.currentPosition}
              onChange={setField('currentPosition')}
              inputProps={{ maxLength: 150 }}
            />
            <TextField
              label="Location"
              value={form.location}
              onChange={setField('location')}
              inputProps={{ maxLength: 120 }}
            />
            <TextField select label="Status" value={form.status} onChange={setField('status')}>
              {STATUS_OPTIONS.map((option) => (
                <MenuItem key={option} value={option}>
                  {option.replace(/_/g, ' ')}
                </MenuItem>
              ))}
            </TextField>
          </Box>

          <TextField
            label="Notes"
            value={form.notes}
            onChange={setField('notes')}
            multiline
            minRows={3}
            fullWidth
            inputProps={{ maxLength: 4000 }}
            helperText={`${form.notes.length}/4000`}
            sx={{ mb: 3 }}
          />

          <Stack direction="row" spacing={1} justifyContent="flex-end">
            <Button onClick={() => navigate(isEdit ? `/candidates/${id}` : '/candidates')} disabled={submitting}>
              Cancel
            </Button>
            <Button
              type="submit"
              variant="contained"
              startIcon={submitting ? <CircularProgress size={16} color="inherit" /> : <SaveIcon />}
              disabled={submitting}
            >
              {isEdit ? 'Save changes' : 'Create candidate'}
            </Button>
          </Stack>
        </Box>
      </Paper>
    </Box>
  );
}
