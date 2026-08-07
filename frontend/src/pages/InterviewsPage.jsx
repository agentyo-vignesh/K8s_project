import { useEffect, useMemo, useState } from 'react';
import {
  Box,
  Button,
  Chip,
  IconButton,
  InputAdornment,
  MenuItem,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TablePagination,
  TableRow,
  TableSortLabel,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';
import EditIcon from '@mui/icons-material/Edit';
import SearchIcon from '@mui/icons-material/Search';
import VisibilityIcon from '@mui/icons-material/Visibility';
import { Link as RouterLink, useNavigate } from 'react-router-dom';
import { interviewApi } from '../api/endpoints';
import { useAuth } from '../auth/AuthContext';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { useNotifications } from '../components/NotificationProvider';
import { PageHeader } from '../components/PageHeader';
import { EmptyState, ErrorState, LoadingState } from '../components/StateViews';
import { InterviewStatusChip } from '../components/StatusChip';
import { useApiResource } from '../hooks/useApiResource';
import { useDebouncedValue } from '../hooks/useDebouncedValue';
import { formatDateTime, formatRelative } from '../utils/datetime';

const STATUS_OPTIONS = ['SCHEDULED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'];

export function InterviewsPage() {
  const navigate = useNavigate();
  const { canManage, isAdmin, user } = useAuth();
  const { notifySuccess, notifyError } = useNotifications();

  const [searchInput, setSearchInput] = useState('');
  const [status, setStatus] = useState('');
  const [page, setPage] = useState(0);
  const [size, setSize] = useState(20);
  const [sortField, setSortField] = useState('scheduledAt');
  const [sortDirection, setSortDirection] = useState('desc');
  const [pendingDelete, setPendingDelete] = useState(null);
  const [deleting, setDeleting] = useState(false);

  const search = useDebouncedValue(searchInput, 350);

  useEffect(() => {
    setPage(0);
  }, [search, status, size]);

  const params = useMemo(
    () => ({
      ...(search ? { search } : {}),
      ...(status ? { status } : {}),
      page,
      size,
      sort: `${sortField},${sortDirection}`,
    }),
    [search, status, page, size, sortField, sortDirection],
  );

  const { data, loading, error, reload } = useApiResource(
    () => interviewApi.search(params),
    [params],
  );

  const handleSort = (field) => {
    if (sortField === field) {
      setSortDirection((direction) => (direction === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortField(field);
      setSortDirection('asc');
    }
  };

  const confirmDelete = async () => {
    setDeleting(true);
    try {
      await interviewApi.remove(pendingDelete.id);
      notifySuccess('Interview deleted.');
      setPendingDelete(null);
      reload();
    } catch (caught) {
      notifyError(caught, 'Could not delete this interview.');
    } finally {
      setDeleting(false);
    }
  };

  const interviews = data?.content || [];
  const hasFilters = Boolean(search || status);
  const isCandidate = user?.role === 'CANDIDATE';

  return (
    <Box>
      <PageHeader
        title={isCandidate ? 'My interviews' : 'Interviews'}
        description={
          isCandidate
            ? 'Your scheduled and completed interviews.'
            : 'Schedule interviews, generate questions and record results.'
        }
        actions={
          canManage ? (
            <Button variant="contained" startIcon={<AddIcon />} onClick={() => navigate('/interviews/new')}>
              Schedule interview
            </Button>
          ) : null
        }
      />

      <Paper sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
          <TextField
            label="Search"
            placeholder="Interview title, role or candidate name"
            value={searchInput}
            onChange={(event) => setSearchInput(event.target.value)}
            fullWidth
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" />
                </InputAdornment>
              ),
            }}
          />
          <TextField
            select
            label="Status"
            value={status}
            onChange={(event) => setStatus(event.target.value)}
            sx={{ minWidth: 200 }}
          >
            <MenuItem value="">All statuses</MenuItem>
            {STATUS_OPTIONS.map((option) => (
              <MenuItem key={option} value={option}>
                {option.replace(/_/g, ' ')}
              </MenuItem>
            ))}
          </TextField>
        </Stack>
      </Paper>

      {loading && !data ? <LoadingState label="Loading interviews…" /> : null}

      {error && !data ? (
        <ErrorState message={error.message} requestId={error.requestId} onRetry={reload} />
      ) : null}

      {data && interviews.length === 0 ? (
        <EmptyState
          title={hasFilters ? 'No interviews match those filters' : 'No interviews yet'}
          description={
            hasFilters
              ? 'Try a different search term or clear the status filter.'
              : isCandidate
                ? 'Nothing has been scheduled for you yet.'
                : 'Schedule the first interview to get started.'
          }
          action={
            hasFilters ? (
              <Button
                onClick={() => {
                  setSearchInput('');
                  setStatus('');
                }}
              >
                Clear filters
              </Button>
            ) : canManage ? (
              <Button variant="contained" startIcon={<AddIcon />} onClick={() => navigate('/interviews/new')}>
                Schedule interview
              </Button>
            ) : null
          }
        />
      ) : null}

      {data && interviews.length > 0 ? (
        <Paper>
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>
                    <TableSortLabel
                      active={sortField === 'title'}
                      direction={sortField === 'title' ? sortDirection : 'asc'}
                      onClick={() => handleSort('title')}
                    >
                      Interview
                    </TableSortLabel>
                  </TableCell>
                  {!isCandidate ? <TableCell>Candidate</TableCell> : null}
                  <TableCell>Interviewer</TableCell>
                  <TableCell>
                    <TableSortLabel
                      active={sortField === 'scheduledAt'}
                      direction={sortField === 'scheduledAt' ? sortDirection : 'asc'}
                      onClick={() => handleSort('scheduledAt')}
                    >
                      Scheduled
                    </TableSortLabel>
                  </TableCell>
                  <TableCell>
                    <TableSortLabel
                      active={sortField === 'status'}
                      direction={sortField === 'status' ? sortDirection : 'asc'}
                      onClick={() => handleSort('status')}
                    >
                      Status
                    </TableSortLabel>
                  </TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {interviews.map((interview) => (
                  <TableRow key={interview.id} hover>
                    <TableCell sx={{ maxWidth: 320 }}>
                      <Typography
                        component={RouterLink}
                        to={`/interviews/${interview.id}`}
                        variant="body2"
                        sx={{ fontWeight: 600, color: 'primary.main', textDecoration: 'none' }}
                      >
                        {interview.title}
                      </Typography>
                      <Typography variant="caption" color="text.secondary" display="block">
                        {interview.roleTitle} · Round {interview.roundNumber} · {interview.experienceLevel}
                      </Typography>
                    </TableCell>
                    {!isCandidate ? (
                      <TableCell>
                        <Typography variant="body2">{interview.candidateName}</Typography>
                        <Typography variant="caption" color="text.secondary">
                          {interview.candidateEmail}
                        </Typography>
                      </TableCell>
                    ) : null}
                    <TableCell>
                      {interview.interviewerName || (
                        <Chip size="small" label="Unassigned" color="warning" variant="outlined" />
                      )}
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">{formatDateTime(interview.scheduledAt)}</Typography>
                      <Typography variant="caption" color="text.secondary">
                        {formatRelative(interview.scheduledAt)}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Stack direction="row" spacing={0.5} alignItems="center">
                        <InterviewStatusChip value={interview.status} />
                        {interview.resultSubmitted ? (
                          <Chip size="small" label="Scored" color="success" variant="outlined" />
                        ) : null}
                      </Stack>
                    </TableCell>
                    <TableCell align="right">
                      <Tooltip title="View">
                        <IconButton
                          size="small"
                          onClick={() => navigate(`/interviews/${interview.id}`)}
                          aria-label={`View ${interview.title}`}
                        >
                          <VisibilityIcon fontSize="small" />
                        </IconButton>
                      </Tooltip>
                      {/* Editing a terminal interview is refused by the API, so it is not offered. */}
                      {canManage && !['COMPLETED', 'CANCELLED'].includes(interview.status) ? (
                        <Tooltip title="Edit">
                          <IconButton
                            size="small"
                            onClick={() => navigate(`/interviews/${interview.id}/edit`)}
                            aria-label={`Edit ${interview.title}`}
                          >
                            <EditIcon fontSize="small" />
                          </IconButton>
                        </Tooltip>
                      ) : null}
                      {isAdmin ? (
                        <Tooltip title="Delete">
                          <IconButton
                            size="small"
                            color="error"
                            onClick={() => setPendingDelete(interview)}
                            aria-label={`Delete ${interview.title}`}
                          >
                            <DeleteIcon fontSize="small" />
                          </IconButton>
                        </Tooltip>
                      ) : null}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
          <TablePagination
            component="div"
            count={data.totalElements}
            page={data.page}
            rowsPerPage={data.size}
            rowsPerPageOptions={[10, 20, 50, 100]}
            onPageChange={(event, nextPage) => setPage(nextPage)}
            onRowsPerPageChange={(event) => setSize(Number(event.target.value))}
          />
        </Paper>
      ) : null}

      <ConfirmDialog
        open={Boolean(pendingDelete)}
        title="Delete interview?"
        message={`This permanently deletes "${pendingDelete?.title || 'this interview'}".`}
        warning="Its questions and submitted result are deleted as well. This cannot be undone."
        confirmLabel="Delete"
        destructive
        busy={deleting}
        onConfirm={confirmDelete}
        onCancel={() => setPendingDelete(null)}
      />
    </Box>
  );
}
