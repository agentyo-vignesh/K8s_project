import { useEffect, useMemo, useState } from 'react';
import {
  Autocomplete,
  Box,
  Button,
  Chip,
  CircularProgress,
  MenuItem,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import SaveIcon from '@mui/icons-material/Save';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { candidateApi, interviewApi, userApi } from '../api/endpoints';
import { useNotifications } from '../components/NotificationProvider';
import { PageHeader } from '../components/PageHeader';
import { ErrorState, LoadingState } from '../components/StateViews';
import { useApiResource } from '../hooks/useApiResource';
import { defaultScheduledAt, fromDateTimeLocalValue, toDateTimeLocalValue } from '../utils/datetime';

const EXPERIENCE_LEVELS = ['JUNIOR', 'MID', 'SENIOR', 'LEAD'];

/** Common focus skills offered as suggestions; the field accepts anything the user types. */
const SKILL_SUGGESTIONS = [
  'Kubernetes',
  'Docker',
  'Helm',
  'ArgoCD',
  'EKS',
  'Terraform',
  'AWS',
  'CI/CD',
  'GitHub Actions',
  'Prometheus',
  'Grafana',
  'Loki',
  'Java',
  'Spring Boot',
  'Python',
  'FastAPI',
  'PostgreSQL',
  'React',
  'Linux',
  'Networking',
  'Incident Response',
  'Observability',
];

function validate(form) {
  const errors = {};
  if (!form.candidateId) errors.candidateId = 'Select a candidate';
  if (!form.title.trim()) errors.title = 'Title is required';
  if (!form.roleTitle.trim()) errors.roleTitle = 'Role title is required';
  if (!form.scheduledAtLocal) errors.scheduledAtLocal = 'Scheduled time is required';
  if (form.focusSkills.length === 0) errors.focusSkills = 'Add at least one focus skill';

  const duration = Number(form.durationMinutes);
  if (Number.isNaN(duration) || duration < 15 || duration > 480) {
    errors.durationMinutes = 'Between 15 and 480 minutes';
  }
  const round = Number(form.roundNumber);
  if (Number.isNaN(round) || round < 1 || round > 10) {
    errors.roundNumber = 'Between 1 and 10';
  }
  return errors;
}

export function InterviewFormPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { notifySuccess, notifyError } = useNotifications();
  const isEdit = Boolean(id);

  const [form, setForm] = useState({
    candidateId: searchParams.get('candidateId') || '',
    interviewerId: '',
    title: '',
    roleTitle: '',
    experienceLevel: 'MID',
    roundNumber: '1',
    scheduledAtLocal: defaultScheduledAt(),
    durationMinutes: '60',
    focusSkills: [],
  });
  const [errors, setErrors] = useState({});
  const [submitting, setSubmitting] = useState(false);

  // A generous page size: the picker is a dropdown, not a paged list, and this keeps it to one
  // request. A deployment with thousands of candidates would want a server-side typeahead instead.
  const candidatesResource = useApiResource(
    () => candidateApi.search({ page: 0, size: 100, sort: 'lastName,asc' }),
    [],
  );
  const interviewersResource = useApiResource(() => userApi.listByRole('INTERVIEWER'), []);
  const interviewResource = useApiResource(() => interviewApi.findById(id), [id], { skip: !isEdit });

  // Memoised because `|| []` allocates a fresh array whenever the resource has no data yet, which
  // would give `selectedCandidate` a new dependency identity on every render.
  const candidates = useMemo(
    () => candidatesResource.data?.content || [],
    [candidatesResource.data],
  );
  const interviewers = interviewersResource.data || [];
  const existing = interviewResource.data;

  useEffect(() => {
    if (!existing) return;
    setForm({
      candidateId: existing.candidateId || '',
      interviewerId: existing.interviewerId || '',
      title: existing.title || '',
      roleTitle: existing.roleTitle || '',
      experienceLevel: existing.experienceLevel || 'MID',
      roundNumber: String(existing.roundNumber ?? 1),
      scheduledAtLocal: toDateTimeLocalValue(existing.scheduledAt),
      durationMinutes: String(existing.durationMinutes ?? 60),
      focusSkills: existing.focusSkills || [],
    });
  }, [existing]);

  const selectedCandidate = useMemo(
    () => candidates.find((candidate) => candidate.id === form.candidateId) || null,
    [candidates, form.candidateId],
  );

  const setField = (field) => (event) => {
    setForm((current) => ({ ...current, [field]: event.target.value }));
    setErrors((current) => ({ ...current, [field]: undefined }));
  };

  /**
   * Selecting a candidate pre-fills the role and level from their profile. It stays editable: this
   * interview may be for a different role than the one on the candidate record.
   */
  const handleCandidateChange = (candidate) => {
    setForm((current) => ({
      ...current,
      candidateId: candidate?.id || '',
      roleTitle: current.roleTitle || candidate?.currentPosition || '',
      focusSkills:
        current.focusSkills.length > 0
          ? current.focusSkills
          : candidate?.primarySkill
            ? [candidate.primarySkill]
            : [],
    }));
    setErrors((current) => ({ ...current, candidateId: undefined }));
  };

  const handleSubmit = async (event) => {
    event.preventDefault();
    const validationErrors = validate(form);
    if (Object.keys(validationErrors).length > 0) {
      setErrors(validationErrors);
      return;
    }

    const scheduledAt = fromDateTimeLocalValue(form.scheduledAtLocal);
    const basePayload = {
      title: form.title.trim(),
      roleTitle: form.roleTitle.trim(),
      experienceLevel: form.experienceLevel,
      roundNumber: Number(form.roundNumber),
      scheduledAt,
      durationMinutes: Number(form.durationMinutes),
      focusSkills: form.focusSkills,
    };

    setSubmitting(true);
    try {
      if (isEdit) {
        await interviewApi.update(id, basePayload);
        // Interviewer changes go through the dedicated endpoint, which validates that the target user
        // can actually act as an interviewer.
        if (form.interviewerId && form.interviewerId !== existing?.interviewerId) {
          await interviewApi.assignInterviewer(id, form.interviewerId);
        }
        notifySuccess('Interview updated.');
        navigate(`/interviews/${id}`);
      } else {
        const { data: created } = await interviewApi.create({
          ...basePayload,
          candidateId: form.candidateId,
          interviewerId: form.interviewerId || null,
        });
        notifySuccess('Interview scheduled.');
        navigate(`/interviews/${created.id}`);
      }
    } catch (caught) {
      notifyError(caught, 'Could not save this interview.');
    } finally {
      setSubmitting(false);
    }
  };

  if (isEdit && interviewResource.loading && !existing) {
    return <LoadingState label="Loading interview…" />;
  }
  if (isEdit && interviewResource.error && !existing) {
    return (
      <ErrorState
        message={interviewResource.error.message}
        requestId={interviewResource.error.requestId}
        onRetry={interviewResource.reload}
      />
    );
  }

  return (
    <Box>
      <PageHeader
        title={isEdit ? 'Edit interview' : 'Schedule interview'}
        description={
          isEdit
            ? 'Update the schedule, focus skills or assigned interviewer.'
            : 'Focus skills drive the questions the AI service generates.'
        }
        backTo={isEdit ? `/interviews/${id}` : '/interviews'}
      />

      <Paper sx={{ p: 3, maxWidth: 900 }}>
        <Box component="form" onSubmit={handleSubmit} noValidate>
          <Typography variant="subtitle2" color="text.secondary" gutterBottom>
            Participants
          </Typography>
          <Box sx={{ display: 'grid', gap: 2, gridTemplateColumns: { xs: '1fr', sm: '1fr 1fr' }, mb: 3 }}>
            <Autocomplete
              options={candidates}
              value={selectedCandidate}
              // The candidate cannot change after creation: moving an interview would orphan its
              // questions and result, so that is a delete-and-recreate.
              disabled={isEdit || candidatesResource.loading}
              onChange={(event, candidate) => handleCandidateChange(candidate)}
              getOptionLabel={(candidate) => `${candidate.fullName} (${candidate.email})`}
              isOptionEqualToValue={(option, value) => option.id === value.id}
              renderInput={(params) => (
                <TextField
                  {...params}
                  label="Candidate"
                  required
                  error={Boolean(errors.candidateId)}
                  helperText={
                    errors.candidateId ||
                    (isEdit ? 'Cannot be changed after scheduling' : undefined)
                  }
                />
              )}
            />
            <TextField
              select
              label="Interviewer"
              value={form.interviewerId}
              onChange={setField('interviewerId')}
              disabled={interviewersResource.loading}
              helperText="Optional; can be assigned later"
            >
              <MenuItem value="">Unassigned</MenuItem>
              {interviewers.map((interviewer) => (
                <MenuItem key={interviewer.id} value={interviewer.id}>
                  {interviewer.fullName}
                </MenuItem>
              ))}
            </TextField>
          </Box>

          <Typography variant="subtitle2" color="text.secondary" gutterBottom>
            Interview
          </Typography>
          <Box sx={{ display: 'grid', gap: 2, gridTemplateColumns: { xs: '1fr', sm: '1fr 1fr' }, mb: 2 }}>
            <TextField
              label="Title"
              value={form.title}
              onChange={setField('title')}
              error={Boolean(errors.title)}
              helperText={errors.title || 'e.g. DevOps Round 1 - Kubernetes Deep Dive'}
              required
              inputProps={{ maxLength: 180 }}
            />
            <TextField
              label="Role title"
              value={form.roleTitle}
              onChange={setField('roleTitle')}
              error={Boolean(errors.roleTitle)}
              helperText={errors.roleTitle || 'The role being interviewed for'}
              required
              inputProps={{ maxLength: 150 }}
            />
            <TextField
              select
              label="Experience level"
              value={form.experienceLevel}
              onChange={setField('experienceLevel')}
              helperText="Drives AI question difficulty"
            >
              {EXPERIENCE_LEVELS.map((level) => (
                <MenuItem key={level} value={level}>
                  {level}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              label="Round"
              type="number"
              value={form.roundNumber}
              onChange={setField('roundNumber')}
              error={Boolean(errors.roundNumber)}
              helperText={errors.roundNumber}
              inputProps={{ min: 1, max: 10 }}
            />
            <TextField
              label="Scheduled at"
              type="datetime-local"
              value={form.scheduledAtLocal}
              onChange={setField('scheduledAtLocal')}
              error={Boolean(errors.scheduledAtLocal)}
              helperText={errors.scheduledAtLocal || 'Your local time; stored as UTC'}
              required
              InputLabelProps={{ shrink: true }}
            />
            <TextField
              label="Duration (minutes)"
              type="number"
              value={form.durationMinutes}
              onChange={setField('durationMinutes')}
              error={Boolean(errors.durationMinutes)}
              helperText={errors.durationMinutes}
              inputProps={{ min: 15, max: 480, step: 15 }}
            />
          </Box>

          <Autocomplete
            multiple
            freeSolo
            options={SKILL_SUGGESTIONS}
            value={form.focusSkills}
            onChange={(event, skills) => {
              // Trim and de-duplicate here so the same normalisation the API applies is visible in
              // the UI rather than surprising the user after save.
              const cleaned = [
                ...new Set(skills.map((skill) => skill.trim()).filter(Boolean)),
              ].slice(0, 20);
              setForm((current) => ({ ...current, focusSkills: cleaned }));
              setErrors((current) => ({ ...current, focusSkills: undefined }));
            }}
            renderTags={(value, getTagProps) =>
              value.map((skill, index) => (
                <Chip size="small" label={skill} {...getTagProps({ index })} key={skill} />
              ))
            }
            renderInput={(params) => (
              <TextField
                {...params}
                label="Focus skills"
                required
                error={Boolean(errors.focusSkills)}
                helperText={
                  errors.focusSkills || 'Type to add your own. Up to 20; these drive question generation.'
                }
              />
            )}
            sx={{ mb: 3 }}
          />

          <Stack direction="row" spacing={1} justifyContent="flex-end">
            <Button onClick={() => navigate(isEdit ? `/interviews/${id}` : '/interviews')} disabled={submitting}>
              Cancel
            </Button>
            <Button
              type="submit"
              variant="contained"
              startIcon={submitting ? <CircularProgress size={16} color="inherit" /> : <SaveIcon />}
              disabled={submitting}
            >
              {isEdit ? 'Save changes' : 'Schedule interview'}
            </Button>
          </Stack>
        </Box>
      </Paper>
    </Box>
  );
}
