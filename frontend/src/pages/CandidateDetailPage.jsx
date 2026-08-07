import { useRef, useState } from 'react';
import {
  Box,
  Button,
  Card,
  CardContent,
  Divider,
  IconButton,
  LinearProgress,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Tooltip,
  Typography,
} from '@mui/material';
import DeleteIcon from '@mui/icons-material/Delete';
import DownloadIcon from '@mui/icons-material/Download';
import EditIcon from '@mui/icons-material/Edit';
import EventNoteIcon from '@mui/icons-material/EventNote';
import UploadFileIcon from '@mui/icons-material/UploadFile';
import { useNavigate, useParams } from 'react-router-dom';
import { candidateApi, resumeApi, triggerBlobDownload } from '../api/endpoints';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { useNotifications } from '../components/NotificationProvider';
import { PageHeader } from '../components/PageHeader';
import { ErrorState, LoadingState } from '../components/StateViews';
import { CandidateStatusChip } from '../components/StatusChip';
import { useApiResource } from '../hooks/useApiResource';
import { formatDateTime } from '../utils/datetime';

const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const ACCEPTED_TYPES = '.pdf,.doc,.docx,.txt';

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function DetailRow({ label, value }) {
  return (
    <Stack direction="row" spacing={2} sx={{ py: 0.75 }}>
      <Typography variant="body2" color="text.secondary" sx={{ minWidth: 150 }}>
        {label}
      </Typography>
      <Typography variant="body2" sx={{ fontWeight: 500, wordBreak: 'break-word' }}>
        {value || '—'}
      </Typography>
    </Stack>
  );
}

export function CandidateDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { notifySuccess, notifyError, notifyMessage } = useNotifications();
  const fileInputRef = useRef(null);

  const [uploadProgress, setUploadProgress] = useState(null);
  const [pendingResumeDelete, setPendingResumeDelete] = useState(null);
  const [deletingResume, setDeletingResume] = useState(false);

  const candidateResource = useApiResource(() => candidateApi.findById(id), [id]);
  const resumeResource = useApiResource(() => resumeApi.listForCandidate(id), [id]);

  const candidate = candidateResource.data;
  const resumes = resumeResource.data || [];

  const handleFileSelected = async (event) => {
    const file = event.target.files?.[0];
    // Reset immediately so selecting the same file twice still fires a change event.
    event.target.value = '';
    if (!file) return;

    // Checked here as well as server-side: rejecting a 60 MB file before it is uploaded saves the
    // user a minute of waiting for a 413.
    if (file.size > MAX_UPLOAD_BYTES) {
      notifyMessage(`${file.name} is ${formatBytes(file.size)}; the limit is 10 MB.`);
      return;
    }

    setUploadProgress(0);
    try {
      await resumeApi.upload(id, file, setUploadProgress);
      notifySuccess(`${file.name} uploaded.`);
      resumeResource.reload();
      candidateResource.reload();
    } catch (caught) {
      notifyError(caught, 'Could not upload this resume.');
    } finally {
      setUploadProgress(null);
    }
  };

  const handleDownload = async (resume) => {
    try {
      const { data } = await resumeApi.download(resume.id);
      triggerBlobDownload(data, resume.originalFilename);
    } catch (caught) {
      notifyError(caught, 'Could not download this resume.');
    }
  };

  const confirmResumeDelete = async () => {
    setDeletingResume(true);
    try {
      await resumeApi.remove(pendingResumeDelete.id);
      notifySuccess('Resume deleted.');
      setPendingResumeDelete(null);
      resumeResource.reload();
      candidateResource.reload();
    } catch (caught) {
      notifyError(caught, 'Could not delete this resume.');
    } finally {
      setDeletingResume(false);
    }
  };

  if (candidateResource.loading && !candidate) {
    return <LoadingState label="Loading candidate…" />;
  }
  if (candidateResource.error && !candidate) {
    return (
      <ErrorState
        message={candidateResource.error.message}
        requestId={candidateResource.error.requestId}
        onRetry={candidateResource.reload}
      />
    );
  }

  return (
    <Box>
      <PageHeader
        title={candidate.fullName}
        description={`${candidate.primarySkill} · ${Number(candidate.yearsOfExperience).toFixed(1)} years`}
        backTo="/candidates"
        actions={
          <>
            <Button
              startIcon={<EventNoteIcon />}
              onClick={() => navigate(`/interviews/new?candidateId=${candidate.id}`)}
            >
              Schedule interview
            </Button>
            <Button
              variant="contained"
              startIcon={<EditIcon />}
              onClick={() => navigate(`/candidates/${candidate.id}/edit`)}
            >
              Edit
            </Button>
          </>
        }
      />

      <Box sx={{ display: 'grid', gap: 2, gridTemplateColumns: { xs: '1fr', lg: '1fr 1fr' } }}>
        <Card>
          <CardContent>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
              <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
                Details
              </Typography>
              <CandidateStatusChip value={candidate.status} />
            </Stack>
            <Divider sx={{ mb: 1 }} />
            <DetailRow label="Email" value={candidate.email} />
            <DetailRow label="Phone" value={candidate.phone} />
            <DetailRow label="Current company" value={candidate.currentCompany} />
            <DetailRow label="Current position" value={candidate.currentPosition} />
            <DetailRow label="Location" value={candidate.location} />
            <DetailRow label="Interviews" value={candidate.interviewCount ?? 0} />
            <DetailRow label="Resumes on file" value={candidate.resumeCount ?? 0} />
            <DetailRow label="Added" value={formatDateTime(candidate.createdAt)} />
            <DetailRow label="Last updated" value={formatDateTime(candidate.updatedAt)} />
            {candidate.notes ? (
              <>
                <Divider sx={{ my: 1.5 }} />
                <Typography variant="body2" color="text.secondary" gutterBottom>
                  Notes
                </Typography>
                <Typography variant="body2" sx={{ whiteSpace: 'pre-wrap' }}>
                  {candidate.notes}
                </Typography>
              </>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardContent>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
              <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
                Resumes
              </Typography>
              <Button
                size="small"
                startIcon={<UploadFileIcon />}
                onClick={() => fileInputRef.current?.click()}
                disabled={uploadProgress !== null}
              >
                Upload
              </Button>
            </Stack>
            <input
              ref={fileInputRef}
              type="file"
              accept={ACCEPTED_TYPES}
              onChange={handleFileSelected}
              hidden
              aria-hidden="true"
            />
            <Divider sx={{ mb: 1 }} />

            {uploadProgress !== null ? (
              <Box sx={{ mb: 2 }}>
                <Typography variant="caption" color="text.secondary">
                  Uploading… {uploadProgress}%
                </Typography>
                <LinearProgress variant="determinate" value={uploadProgress} />
              </Box>
            ) : null}

            {resumeResource.loading && resumes.length === 0 ? (
              <LoadingState label="Loading resumes…" minHeight={120} />
            ) : null}

            {!resumeResource.loading && resumes.length === 0 ? (
              <Typography variant="body2" color="text.secondary">
                No resumes uploaded. Accepted formats: PDF, DOC, DOCX, TXT (max 10 MB).
              </Typography>
            ) : null}

            {resumes.length > 0 ? (
              <TableContainer>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>File</TableCell>
                      <TableCell align="right">Size</TableCell>
                      <TableCell>Uploaded</TableCell>
                      <TableCell align="right">Actions</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {resumes.map((resume) => (
                      <TableRow key={resume.id} hover>
                        <TableCell sx={{ maxWidth: 220 }}>
                          <Typography variant="body2" noWrap title={resume.originalFilename}>
                            {resume.originalFilename}
                          </Typography>
                          <Typography variant="caption" color="text.secondary">
                            {resume.storageType}
                          </Typography>
                        </TableCell>
                        <TableCell align="right">{formatBytes(resume.sizeBytes)}</TableCell>
                        <TableCell>{formatDateTime(resume.uploadedAt, 'dd MMM, HH:mm')}</TableCell>
                        <TableCell align="right">
                          <Tooltip title="Download">
                            <IconButton
                              size="small"
                              onClick={() => handleDownload(resume)}
                              aria-label={`Download ${resume.originalFilename}`}
                            >
                              <DownloadIcon fontSize="small" />
                            </IconButton>
                          </Tooltip>
                          <Tooltip title="Delete">
                            <IconButton
                              size="small"
                              color="error"
                              onClick={() => setPendingResumeDelete(resume)}
                              aria-label={`Delete ${resume.originalFilename}`}
                            >
                              <DeleteIcon fontSize="small" />
                            </IconButton>
                          </Tooltip>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </TableContainer>
            ) : null}
          </CardContent>
        </Card>
      </Box>

      <Paper sx={{ p: 2, mt: 2 }}>
        <Typography variant="caption" color="text.secondary">
          Candidate id {candidate.id} — quote this when reporting an issue.
        </Typography>
      </Paper>

      <ConfirmDialog
        open={Boolean(pendingResumeDelete)}
        title="Delete resume?"
        message={`This permanently deletes ${pendingResumeDelete?.originalFilename || 'this file'} and its stored contents.`}
        confirmLabel="Delete"
        destructive
        busy={deletingResume}
        onConfirm={confirmResumeDelete}
        onCancel={() => setPendingResumeDelete(null)}
      />
    </Box>
  );
}
