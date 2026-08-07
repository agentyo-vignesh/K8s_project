import { useEffect, useMemo, useState } from 'react';
import {
  Box,
  Button,
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
import { candidateApi } from '../api/endpoints';
import { useAuth } from '../auth/AuthContext';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { useNotifications } from '../components/NotificationProvider';
import { PageHeader } from '../components/PageHeader';
import { EmptyState, ErrorState, LoadingState } from '../components/StateViews';
import { CandidateStatusChip } from '../components/StatusChip';
import { useApiResource } from '../hooks/useApiResource';
import { useDebouncedValue } from '../hooks/useDebouncedValue';
import { formatDate } from '../utils/datetime';

const STATUS_OPTIONS = [
  'NEW',
  'SCREENING',
  'INTERVIEWING',
  'OFFERED',
  'HIRED',
  'REJECTED',
  'ON_HOLD',
];

const COLUMNS = [
  { id: 'lastName', label: 'Candidate', sortable: true },
  { id: 'primarySkill', label: 'Primary skill', sortable: true },
  { id: 'yearsOfExperience', label: 'Experience', sortable: true, align: 'right' },
  { id: 'currentCompany', label: 'Current company', sortable: true },
  { id: 'status', label: 'Status', sortable: true },
  { id: 'createdAt', label: 'Added', sortable: true },
  { id: 'actions', label: 'Actions', sortable: false, align: 'right' },
];

export function CandidatesPage() {
  const navigate = useNavigate();
  const { isAdmin } = useAuth();
  const { notifySuccess, notifyError } = useNotifications();

  const [searchInput, setSearchInput] = useState('');
  const [status, setStatus] = useState('');
  const [page, setPage] = useState(0);
  const [size, setSize] = useState(20);
  const [sortField, setSortField] = useState('createdAt');
  const [sortDirection, setSortDirection] = useState('desc');
  const [pendingDelete, setPendingDelete] = useState(null);
  const [deleting, setDeleting] = useState(false);

  // Debounced so a five-character search term is one request, not five.
  const search = useDebouncedValue(searchInput, 350);

  // Any filter change invalidates the current page number: staying on page 4 of a narrower result
  // set would show an empty table.
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
    () => candidateApi.search(params),
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
      await candidateApi.remove(pendingDelete.id);
      notifySuccess(`${pendingDelete.fullName} was deleted.`);
      setPendingDelete(null);
      reload();
    } catch (caught) {
      notifyError(caught, 'Could not delete this candidate.');
    } finally {
      setDeleting(false);
    }
  };

  const candidates = data?.content || [];
  const hasFilters = Boolean(search || status);

  return (
    <Box>
      <PageHeader
        title="Candidates"
        description="Search, review and maintain the candidate pipeline."
        actions={
          <Button variant="contained" startIcon={<AddIcon />} onClick={() => navigate('/candidates/new')}>
            New candidate
          </Button>
        }
      />

      <Paper sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
          <TextField
            label="Search"
            placeholder="Name, email, skill or company"
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

      {loading && !data ? <LoadingState label="Loading candidates…" /> : null}

      {error && !data ? (
        <ErrorState message={error.message} requestId={error.requestId} onRetry={reload} />
      ) : null}

      {data && candidates.length === 0 ? (
        <EmptyState
          title={hasFilters ? 'No candidates match those filters' : 'No candidates yet'}
          description={
            hasFilters
              ? 'Try a different search term or clear the status filter.'
              : 'Add the first candidate to start scheduling interviews.'
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
            ) : (
              <Button variant="contained" startIcon={<AddIcon />} onClick={() => navigate('/candidates/new')}>
                New candidate
              </Button>
            )
          }
        />
      ) : null}

      {data && candidates.length > 0 ? (
        <Paper>
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  {COLUMNS.map((column) => (
                    <TableCell key={column.id} align={column.align || 'left'}>
                      {column.sortable ? (
                        <TableSortLabel
                          active={sortField === column.id}
                          direction={sortField === column.id ? sortDirection : 'asc'}
                          onClick={() => handleSort(column.id)}
                        >
                          {column.label}
                        </TableSortLabel>
                      ) : (
                        column.label
                      )}
                    </TableCell>
                  ))}
                </TableRow>
              </TableHead>
              <TableBody>
                {candidates.map((candidate) => (
                  <TableRow key={candidate.id} hover>
                    <TableCell>
                      <Typography
                        component={RouterLink}
                        to={`/candidates/${candidate.id}`}
                        variant="body2"
                        sx={{ fontWeight: 600, color: 'primary.main', textDecoration: 'none' }}
                      >
                        {candidate.fullName}
                      </Typography>
                      <Typography variant="caption" color="text.secondary" display="block">
                        {candidate.email}
                      </Typography>
                    </TableCell>
                    <TableCell>{candidate.primarySkill}</TableCell>
                    <TableCell align="right">{Number(candidate.yearsOfExperience).toFixed(1)} yrs</TableCell>
                    <TableCell>{candidate.currentCompany || '—'}</TableCell>
                    <TableCell>
                      <CandidateStatusChip value={candidate.status} />
                    </TableCell>
                    <TableCell>{formatDate(candidate.createdAt)}</TableCell>
                    <TableCell align="right">
                      <Tooltip title="View">
                        <IconButton
                          size="small"
                          onClick={() => navigate(`/candidates/${candidate.id}`)}
                          aria-label={`View ${candidate.fullName}`}
                        >
                          <VisibilityIcon fontSize="small" />
                        </IconButton>
                      </Tooltip>
                      <Tooltip title="Edit">
                        <IconButton
                          size="small"
                          onClick={() => navigate(`/candidates/${candidate.id}/edit`)}
                          aria-label={`Edit ${candidate.fullName}`}
                        >
                          <EditIcon fontSize="small" />
                        </IconButton>
                      </Tooltip>
                      {/* Deletion cascades, so it is ADMIN-only; the API enforces this too. */}
                      {isAdmin ? (
                        <Tooltip title="Delete">
                          <IconButton
                            size="small"
                            color="error"
                            onClick={() => setPendingDelete(candidate)}
                            aria-label={`Delete ${candidate.fullName}`}
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
        title="Delete candidate?"
        message={`This permanently deletes ${pendingDelete?.fullName || 'this candidate'}.`}
        warning="Their interviews, generated questions, results and uploaded resumes are deleted as well. This cannot be undone."
        confirmLabel="Delete"
        destructive
        busy={deleting}
        onConfirm={confirmDelete}
        onCancel={() => setPendingDelete(null)}
      />
    </Box>
  );
}
