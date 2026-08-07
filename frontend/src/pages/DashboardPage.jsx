import { Box, Button, Card, CardContent, Chip, Paper, Stack, Typography } from '@mui/material';
import AssignmentTurnedInIcon from '@mui/icons-material/AssignmentTurnedIn';
import EventAvailableIcon from '@mui/icons-material/EventAvailable';
import PendingActionsIcon from '@mui/icons-material/PendingActions';
import PeopleIcon from '@mui/icons-material/People';
import RefreshIcon from '@mui/icons-material/Refresh';
import { Link as RouterLink } from 'react-router-dom';
import { dashboardApi } from '../api/endpoints';
import { PageHeader } from '../components/PageHeader';
import { ErrorState, LoadingState } from '../components/StateViews';
import { InterviewStatusChip, humanise } from '../components/StatusChip';
import { useApiResource } from '../hooks/useApiResource';
import { formatDateTime, formatRelative } from '../utils/datetime';

function StatCard({ label, value, icon: Icon, color = 'primary' }) {
  return (
    <Card>
      <CardContent>
        <Stack direction="row" alignItems="center" spacing={2}>
          <Box
            sx={{
              width: 48,
              height: 48,
              borderRadius: 2,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              bgcolor: `${color}.main`,
              color: `${color}.contrastText`,
              flexShrink: 0,
            }}
          >
            <Icon />
          </Box>
          <Box sx={{ minWidth: 0 }}>
            <Typography variant="h4" component="p" sx={{ fontWeight: 700, lineHeight: 1.1 }}>
              {value}
            </Typography>
            <Typography variant="body2" color="text.secondary" noWrap>
              {label}
            </Typography>
          </Box>
        </Stack>
      </CardContent>
    </Card>
  );
}

function BreakdownCard({ title, counts, emptyLabel }) {
  const entries = Object.entries(counts || {});
  const total = entries.reduce((sum, [, count]) => sum + count, 0);

  return (
    <Card>
      <CardContent>
        <Typography variant="subtitle1" gutterBottom sx={{ fontWeight: 600 }}>
          {title}
        </Typography>
        {entries.length === 0 ? (
          <Typography variant="body2" color="text.secondary">
            {emptyLabel}
          </Typography>
        ) : (
          <Stack spacing={1.25} sx={{ mt: 1 }}>
            {entries.map(([status, count]) => (
              <Box key={status}>
                <Stack direction="row" justifyContent="space-between" sx={{ mb: 0.5 }}>
                  <Typography variant="body2">{humanise(status)}</Typography>
                  <Typography variant="body2" sx={{ fontWeight: 600 }}>
                    {count}
                  </Typography>
                </Stack>
                {/* A plain proportional bar: enough to read the distribution without a chart library. */}
                <Box sx={{ height: 6, borderRadius: 3, bgcolor: 'action.hover', overflow: 'hidden' }}>
                  <Box
                    sx={{
                      height: '100%',
                      width: total > 0 ? `${(count / total) * 100}%` : 0,
                      bgcolor: 'primary.main',
                    }}
                  />
                </Box>
              </Box>
            ))}
          </Stack>
        )}
      </CardContent>
    </Card>
  );
}

export function DashboardPage() {
  const { data, loading, error, reload } = useApiResource(() => dashboardApi.summary(), []);

  if (loading && !data) {
    return <LoadingState label="Loading dashboard…" />;
  }
  if (error && !data) {
    return <ErrorState message={error.message} requestId={error.requestId} onRetry={reload} />;
  }

  return (
    <Box>
      <PageHeader
        title="Dashboard"
        description={data ? `Figures as of ${formatDateTime(data.generatedAt, 'HH:mm:ss')}` : undefined}
        actions={
          <Button startIcon={<RefreshIcon />} onClick={reload} disabled={loading}>
            Refresh
          </Button>
        }
      />

      <Box
        sx={{
          display: 'grid',
          gap: 2,
          gridTemplateColumns: { xs: '1fr', sm: 'repeat(2, 1fr)', lg: 'repeat(4, 1fr)' },
          mb: 3,
        }}
      >
        <StatCard label="Total candidates" value={data.totalCandidates} icon={PeopleIcon} color="primary" />
        <StatCard label="Total interviews" value={data.totalInterviews} icon={EventAvailableIcon} color="secondary" />
        <StatCard
          label="Completed interviews"
          value={data.completedInterviews}
          icon={AssignmentTurnedInIcon}
          color="success"
        />
        <StatCard label="Pending interviews" value={data.pendingInterviews} icon={PendingActionsIcon} color="warning" />
      </Box>

      <Box
        sx={{
          display: 'grid',
          gap: 2,
          gridTemplateColumns: { xs: '1fr', md: 'repeat(2, 1fr)', lg: 'repeat(3, 1fr)' },
          mb: 3,
        }}
      >
        <BreakdownCard
          title="Candidates by status"
          counts={data.candidatesByStatus}
          emptyLabel="No candidates yet."
        />
        <BreakdownCard
          title="Interviews by status"
          counts={data.interviewsByStatus}
          emptyLabel="No interviews yet."
        />
        <Card>
          <CardContent>
            <Typography variant="subtitle1" gutterBottom sx={{ fontWeight: 600 }}>
              Average interview score
            </Typography>
            {/* Absent, not zero, until a result exists: an average of nothing is not 0.0. */}
            {data.averageOverallScore == null ? (
              <Typography variant="body2" color="text.secondary">
                No results submitted yet.
              </Typography>
            ) : (
              <>
                <Typography variant="h3" sx={{ fontWeight: 700 }}>
                  {Number(data.averageOverallScore).toFixed(1)}
                  <Typography component="span" variant="h6" color="text.secondary">
                    {' '}
                    / 10
                  </Typography>
                </Typography>
                <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap sx={{ mt: 1.5 }}>
                  {Object.entries(data.resultsByRecommendation || {}).map(([recommendation, count]) => (
                    <Chip
                      key={recommendation}
                      size="small"
                      label={`${humanise(recommendation)}: ${count}`}
                      variant="outlined"
                    />
                  ))}
                </Stack>
              </>
            )}
          </CardContent>
        </Card>
      </Box>

      <Paper sx={{ p: 2.5 }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1.5 }}>
          <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
            Next interviews
          </Typography>
          <Button component={RouterLink} to="/interviews" size="small">
            View all
          </Button>
        </Stack>
        {(data.upcomingInterviews || []).length === 0 ? (
          <Typography variant="body2" color="text.secondary">
            Nothing scheduled.
          </Typography>
        ) : (
          <Stack divider={<Box sx={{ borderBottom: '1px solid #eef1f6' }} />}>
            {data.upcomingInterviews.map((interview) => (
              <Stack
                key={interview.id}
                direction={{ xs: 'column', sm: 'row' }}
                justifyContent="space-between"
                alignItems={{ xs: 'flex-start', sm: 'center' }}
                spacing={1}
                sx={{ py: 1.25 }}
              >
                <Box sx={{ minWidth: 0 }}>
                  <Typography
                    component={RouterLink}
                    to={`/interviews/${interview.id}`}
                    variant="body2"
                    sx={{ fontWeight: 600, textDecoration: 'none', color: 'primary.main' }}
                  >
                    {interview.title}
                  </Typography>
                  <Typography variant="caption" color="text.secondary" display="block">
                    {interview.candidateName}
                    {interview.interviewerName ? ` · with ${interview.interviewerName}` : ' · unassigned'}
                  </Typography>
                </Box>
                <Stack direction="row" spacing={1} alignItems="center">
                  <Box sx={{ textAlign: { sm: 'right' } }}>
                    <Typography variant="body2">{formatDateTime(interview.scheduledAt)}</Typography>
                    <Typography variant="caption" color="text.secondary">
                      {formatRelative(interview.scheduledAt)}
                    </Typography>
                  </Box>
                  <InterviewStatusChip value={interview.status} />
                </Stack>
              </Stack>
            ))}
          </Stack>
        )}
      </Paper>
    </Box>
  );
}
