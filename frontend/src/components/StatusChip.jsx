/**
 * Status badges.
 *
 * One component per enum so a status always renders with the same colour and the same humanised
 * label. The API returns `ON_HOLD`; users should read "On hold".
 */
import { Chip } from '@mui/material';
import {
  candidateStatusColor,
  difficultyColor,
  interviewStatusColor,
  recommendationColor,
} from '../theme';

/** `IN_PROGRESS` -> `In progress`. */
export function humanise(value) {
  if (!value) return '';
  const lower = value.toString().replace(/_/g, ' ').toLowerCase();
  return lower.charAt(0).toUpperCase() + lower.slice(1);
}

function BaseChip({ value, colorMap, size = 'small', variant = 'filled' }) {
  if (!value) return null;
  return (
    <Chip
      label={humanise(value)}
      color={colorMap[value] || 'default'}
      size={size}
      variant={variant}
      sx={{ fontWeight: 600 }}
    />
  );
}

export function CandidateStatusChip(props) {
  return <BaseChip {...props} colorMap={candidateStatusColor} />;
}

export function InterviewStatusChip(props) {
  return <BaseChip {...props} colorMap={interviewStatusColor} />;
}

export function RecommendationChip(props) {
  return <BaseChip {...props} colorMap={recommendationColor} />;
}

export function DifficultyChip(props) {
  return <BaseChip {...props} colorMap={difficultyColor} variant="outlined" />;
}
