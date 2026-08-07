import { useState } from 'react';
import {
  Accordion,
  AccordionDetails,
  AccordionSummary,
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Divider,
  MenuItem,
  Paper,
  Slider,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import AutoAwesomeIcon from '@mui/icons-material/AutoAwesome';
import EditIcon from '@mui/icons-material/Edit';
import ExpandMoreIcon from '@mui/icons-material/ExpandMore';
import SaveIcon from '@mui/icons-material/Save';
import { useNavigate, useParams } from 'react-router-dom';
import { interviewApi } from '../api/endpoints';
import { useAuth } from '../auth/AuthContext';
import { useNotifications } from '../components/NotificationProvider';
import { PageHeader } from '../components/PageHeader';
import { ErrorState, LoadingState } from '../components/StateViews';
import {
  DifficultyChip,
  InterviewStatusChip,
  RecommendationChip,
  humanise,
} from '../components/StatusChip';
import { useApiResource } from '../hooks/useApiResource';
import { formatDateTime, formatRelative } from '../utils/datetime';

const RECOMMENDATIONS = ['STRONG_HIRE', 'HIRE', 'HOLD', 'NO_HIRE'];

/** Legal forward transitions, mirroring InterviewStatus.canTransitionTo on the server. */
const ALLOWED_TRANSITIONS = {
  SCHEDULED: ['IN_PROGRESS', 'COMPLETED', 'CANCELLED'],
  IN_PROGRESS: ['COMPLETED', 'CANCELLED'],
  COMPLETED: [],
  CANCELLED: [],
};

function ScoreSlider({ label, value, onChange, disabled }) {
  return (
    <Box>
      <Stack direction="row" justifyContent="space-between">
        <Typography variant="body2">{label}</Typography>
        <Typography variant="body2" sx={{ fontWeight: 700 }}>
          {value.toFixed(1)}
        </Typography>
      </Stack>
      <Slider
        value={value}
        onChange={(event, next) => onChange(next)}
        min={0}
        max={10}
        step={0.5}
        marks={[
          { value: 0, label: '0' },
          { value: 5, label: '5' },
          { value: 10, label: '10' },
        ]}
        disabled={disabled}
        aria-label={label}
      />
    </Box>
  );
}

function DetailRow({ label, value }) {
  return (
    <Stack direction="row" spacing={2} sx={{ py: 0.6 }}>
      <Typography variant="body2" color="text.secondary" sx={{ minWidth: 130 }}>
        {label}
      </Typography>
      <Typography variant="body2" sx={{ fontWeight: 500 }}>
        {value || '—'}
      </Typography>
    </Stack>
  );
}

export function InterviewDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { canManage, user } = useAuth();
  const { notifySuccess, notifyError } = useNotifications();
  const isCandidate = user?.role === 'CANDIDATE';

  const [generating, setGenerating] = useState(false);
  const [questionCount, setQuestionCount] = useState(5);
  const [statusBusy, setStatusBusy] = useState(false);

  const [scores, setScores] = useState({ technical: 7, communication: 7, problemSolving: 7 });
  const [recommendation, setRecommendation] = useState('HIRE');
  const [strengths, setStrengths] = useState('');
  const [improvements, setImprovements] = useState('');
  const [feedback, setFeedback] = useState('');
  const [savingResult, setSavingResult] = useState(false);

  const interviewResource = useApiResource(() => interviewApi.findById(id), [id]);
  const interview = interviewResource.data;

  // Only requested when a result exists, so a missing scorecard is not reported as an error.
  const resultResource = useApiResource(() => interviewApi.findResult(id), [id, interview?.resultSubmitted], {
    skip: !interview?.resultSubmitted,
  });
  const result = resultResource.data;

  const handleGenerate = async () => {
    setGenerating(true);
    try {
      const { data } = await interviewApi.generateQuestions(id, {
        questionCount,
        replaceExisting: true,
      });
      notifySuccess(`Generated ${data.length} question(s).`);
      interviewResource.reload();
    } catch (caught) {
      // A 503 here means the AI service is down. The rest of the page keeps working, which is the
      // point of excluding the AI service from the middleware's readiness group.
      notifyError(caught, 'Could not generate questions. The AI service may be unavailable.');
    } finally {
      setGenerating(false);
    }
  };

  const handleStatusChange = async (nextStatus) => {
    setStatusBusy(true);
    try {
      await interviewApi.updateStatus(id, nextStatus);
      notifySuccess(`Interview moved to ${humanise(nextStatus)}.`);
      interviewResource.reload();
    } catch (caught) {
      notifyError(caught, 'Could not change the status.');
    } finally {
      setStatusBusy(false);
    }
  };

  const handleSubmitResult = async (event) => {
    event.preventDefault();
    if (feedback.trim().length < 20) {
      notifyError(null, 'Feedback must be at least 20 characters.');
      return;
    }
    setSavingResult(true);
    try {
      await interviewApi.submitResult(id, {
        technicalScore: scores.technical,
        communicationScore: scores.communication,
        problemSolvingScore: scores.problemSolving,
        recommendation,
        strengths: strengths.trim() || null,
        improvements: improvements.trim() || null,
        feedback: feedback.trim(),
      });
      notifySuccess('Result recorded; the interview is now completed.');
      interviewResource.reload();
    } catch (caught) {
      notifyError(caught, 'Could not save the result.');
    } finally {
      setSavingResult(false);
    }
  };

  if (interviewResource.loading && !interview) {
    return <LoadingState label="Loading interview…" />;
  }
  if (interviewResource.error && !interview) {
    return (
      <ErrorState
        message={interviewResource.error.message}
        requestId={interviewResource.error.requestId}
        onRetry={interviewResource.reload}
      />
    );
  }

  const questions = interview.questions || [];
  const transitions = ALLOWED_TRANSITIONS[interview.status] || [];
  const isTerminal = ['COMPLETED', 'CANCELLED'].includes(interview.status);
  // The mean of the three sliders, shown live so the interviewer sees the derived headline before
  // submitting. The server recomputes it; this is presentation only.
  const derivedOverall = (
    (scores.technical + scores.communication + scores.problemSolving) / 3
  ).toFixed(1);

  return (
    <Box>
      <PageHeader
        title={interview.title}
        description={`${interview.roleTitle} · Round ${interview.roundNumber} · ${interview.experienceLevel}`}
        backTo="/interviews"
        actions={
          canManage && !isTerminal ? (
            <Button startIcon={<EditIcon />} onClick={() => navigate(`/interviews/${id}/edit`)}>
              Edit
            </Button>
          ) : null
        }
      />

      <Box sx={{ display: 'grid', gap: 2, gridTemplateColumns: { xs: '1fr', lg: '2fr 1fr' } }}>
        <Stack spacing={2}>
          <Card>
            <CardContent>
              <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
                <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
                  Questions ({questions.length})
                </Typography>
                {canManage && !isTerminal ? (
                  <Stack direction="row" spacing={1} alignItems="center">
                    <TextField
                      select
                      label="Count"
                      value={questionCount}
                      onChange={(event) => setQuestionCount(Number(event.target.value))}
                      sx={{ width: 96 }}
                    >
                      {[3, 5, 8, 10, 15, 20].map((count) => (
                        <MenuItem key={count} value={count}>
                          {count}
                        </MenuItem>
                      ))}
                    </TextField>
                    <Button
                      variant="contained"
                      startIcon={
                        generating ? <CircularProgress size={16} color="inherit" /> : <AutoAwesomeIcon />
                      }
                      onClick={handleGenerate}
                      disabled={generating}
                    >
                      {generating ? 'Generating…' : 'Generate with AI'}
                    </Button>
                  </Stack>
                ) : null}
              </Stack>
              <Divider sx={{ mb: 1.5 }} />

              {questions.length === 0 ? (
                <Alert severity="info">
                  No questions yet.
                  {canManage
                    ? ' Use "Generate with AI" to produce a set from the interview\'s focus skills.'
                    : ''}
                </Alert>
              ) : (
                <Stack spacing={1}>
                  {questions.map((question) => (
                    <Accordion key={question.id} disableGutters>
                      <AccordionSummary expandIcon={<ExpandMoreIcon />}>
                        <Stack
                          direction="row"
                          spacing={1.5}
                          alignItems="center"
                          sx={{ width: '100%', pr: 1 }}
                        >
                          <Chip size="small" label={question.sequenceNo} />
                          <Typography variant="body2" sx={{ flexGrow: 1 }}>
                            {question.questionText}
                          </Typography>
                          <DifficultyChip value={question.difficulty} />
                        </Stack>
                      </AccordionSummary>
                      <AccordionDetails>
                        <Stack spacing={1}>
                          <Stack direction="row" spacing={1}>
                            <Chip size="small" variant="outlined" label={question.category} />
                            <Chip
                              size="small"
                              variant="outlined"
                              label={question.source === 'AI' ? 'AI generated' : 'Manual'}
                            />
                          </Stack>
                          {/* The API withholds expectedAnswer from CANDIDATE callers, so this block
                              simply does not render for them. */}
                          {question.expectedAnswer ? (
                            <Box>
                              <Typography variant="caption" color="text.secondary">
                                Interviewer guidance
                              </Typography>
                              <Typography variant="body2" sx={{ whiteSpace: 'pre-wrap' }}>
                                {question.expectedAnswer}
                              </Typography>
                            </Box>
                          ) : (
                            <Typography variant="body2" color="text.secondary">
                              {isCandidate
                                ? 'Model answers are only visible to interviewers.'
                                : 'No guidance was provided for this question.'}
                            </Typography>
                          )}
                        </Stack>
                      </AccordionDetails>
                    </Accordion>
                  ))}
                </Stack>
              )}
            </CardContent>
          </Card>

          {result ? (
            <Card>
              <CardContent>
                <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
                  <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
                    Result
                  </Typography>
                  <RecommendationChip value={result.recommendation} />
                </Stack>
                <Divider sx={{ mb: 1.5 }} />
                <Box
                  sx={{
                    display: 'grid',
                    gap: 2,
                    gridTemplateColumns: { xs: '1fr 1fr', sm: 'repeat(4, 1fr)' },
                    mb: 2,
                  }}
                >
                  {[
                    ['Overall', result.overallScore],
                    ['Technical', result.technicalScore],
                    ['Communication', result.communicationScore],
                    ['Problem solving', result.problemSolvingScore],
                  ].map(([label, value]) => (
                    <Box key={label} sx={{ textAlign: 'center' }}>
                      <Typography variant="h5" sx={{ fontWeight: 700 }}>
                        {Number(value).toFixed(1)}
                      </Typography>
                      <Typography variant="caption" color="text.secondary">
                        {label}
                      </Typography>
                    </Box>
                  ))}
                </Box>
                {result.strengths ? <DetailRow label="Strengths" value={result.strengths} /> : null}
                {result.improvements ? <DetailRow label="To improve" value={result.improvements} /> : null}
                <Divider sx={{ my: 1.5 }} />
                <Typography variant="caption" color="text.secondary">
                  Feedback
                </Typography>
                <Typography variant="body2" sx={{ whiteSpace: 'pre-wrap', mb: 1 }}>
                  {result.feedback}
                </Typography>
                <Typography variant="caption" color="text.disabled">
                  Submitted by {result.submittedByName || 'unknown'} on {formatDateTime(result.submittedAt)}
                </Typography>
              </CardContent>
            </Card>
          ) : null}

          {canManage && !result && interview.status !== 'CANCELLED' ? (
            <Card>
              <CardContent>
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Record result
                </Typography>
                <Alert severity="info" sx={{ mb: 2 }}>
                  Submitting a result marks this interview as completed. The overall score is derived
                  server-side as the mean of the three dimensions — currently <strong>{derivedOverall}</strong>.
                </Alert>
                <Box component="form" onSubmit={handleSubmitResult} noValidate>
                  <Box
                    sx={{
                      display: 'grid',
                      gap: 3,
                      gridTemplateColumns: { xs: '1fr', sm: 'repeat(3, 1fr)' },
                      mb: 2,
                    }}
                  >
                    <ScoreSlider
                      label="Technical"
                      value={scores.technical}
                      onChange={(value) => setScores((current) => ({ ...current, technical: value }))}
                      disabled={savingResult}
                    />
                    <ScoreSlider
                      label="Communication"
                      value={scores.communication}
                      onChange={(value) => setScores((current) => ({ ...current, communication: value }))}
                      disabled={savingResult}
                    />
                    <ScoreSlider
                      label="Problem solving"
                      value={scores.problemSolving}
                      onChange={(value) => setScores((current) => ({ ...current, problemSolving: value }))}
                      disabled={savingResult}
                    />
                  </Box>

                  <Stack spacing={2}>
                    <TextField
                      select
                      label="Recommendation"
                      value={recommendation}
                      onChange={(event) => setRecommendation(event.target.value)}
                      sx={{ maxWidth: 260 }}
                    >
                      {RECOMMENDATIONS.map((option) => (
                        <MenuItem key={option} value={option}>
                          {humanise(option)}
                        </MenuItem>
                      ))}
                    </TextField>
                    <TextField
                      label="Strengths"
                      value={strengths}
                      onChange={(event) => setStrengths(event.target.value)}
                      multiline
                      minRows={2}
                      fullWidth
                      inputProps={{ maxLength: 4000 }}
                    />
                    <TextField
                      label="Areas to improve"
                      value={improvements}
                      onChange={(event) => setImprovements(event.target.value)}
                      multiline
                      minRows={2}
                      fullWidth
                      inputProps={{ maxLength: 4000 }}
                    />
                    <TextField
                      label="Feedback"
                      value={feedback}
                      onChange={(event) => setFeedback(event.target.value)}
                      multiline
                      minRows={4}
                      fullWidth
                      required
                      inputProps={{ maxLength: 8000 }}
                      helperText={`${feedback.length}/8000 — at least 20 characters`}
                      error={feedback.length > 0 && feedback.trim().length < 20}
                    />
                    <Stack direction="row" justifyContent="flex-end">
                      <Button
                        type="submit"
                        variant="contained"
                        startIcon={
                          savingResult ? <CircularProgress size={16} color="inherit" /> : <SaveIcon />
                        }
                        disabled={savingResult}
                      >
                        Submit result
                      </Button>
                    </Stack>
                  </Stack>
                </Box>
              </CardContent>
            </Card>
          ) : null}
        </Stack>

        <Stack spacing={2}>
          <Card>
            <CardContent>
              <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
                <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
                  Details
                </Typography>
                <InterviewStatusChip value={interview.status} />
              </Stack>
              <Divider sx={{ mb: 1 }} />
              <DetailRow label="Candidate" value={interview.candidateName} />
              <DetailRow label="Email" value={interview.candidateEmail} />
              <DetailRow label="Interviewer" value={interview.interviewerName || 'Unassigned'} />
              <DetailRow label="Scheduled" value={formatDateTime(interview.scheduledAt)} />
              <DetailRow label="Relative" value={formatRelative(interview.scheduledAt)} />
              <DetailRow label="Duration" value={`${interview.durationMinutes} minutes`} />
              <Divider sx={{ my: 1.5 }} />
              <Typography variant="caption" color="text.secondary" gutterBottom display="block">
                Focus skills
              </Typography>
              <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap>
                {(interview.focusSkills || []).map((skill) => (
                  <Chip key={skill} size="small" label={skill} variant="outlined" />
                ))}
              </Stack>
            </CardContent>
          </Card>

          {canManage && transitions.length > 0 ? (
            <Card>
              <CardContent>
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Change status
                </Typography>
                <Divider sx={{ mb: 1.5 }} />
                <Stack spacing={1}>
                  {transitions.map((nextStatus) => (
                    <Button
                      key={nextStatus}
                      variant="outlined"
                      color={nextStatus === 'CANCELLED' ? 'error' : 'primary'}
                      onClick={() => handleStatusChange(nextStatus)}
                      disabled={statusBusy}
                      fullWidth
                    >
                      Move to {humanise(nextStatus)}
                    </Button>
                  ))}
                </Stack>
              </CardContent>
            </Card>
          ) : null}

          <Paper sx={{ p: 2 }}>
            <Typography variant="caption" color="text.secondary">
              Interview id {interview.id} — quote this when reporting an issue.
            </Typography>
          </Paper>
        </Stack>
      </Box>
    </Box>
  );
}
