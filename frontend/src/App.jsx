import { Navigate, Route, Routes } from 'react-router-dom';
import { ProtectedRoute } from './auth/ProtectedRoute';
import { AppLayout } from './components/AppLayout';
import { CandidateDetailPage } from './pages/CandidateDetailPage';
import { CandidateFormPage } from './pages/CandidateFormPage';
import { CandidatesPage } from './pages/CandidatesPage';
import { DashboardPage } from './pages/DashboardPage';
import { ForbiddenPage } from './pages/ForbiddenPage';
import { InterviewDetailPage } from './pages/InterviewDetailPage';
import { InterviewFormPage } from './pages/InterviewFormPage';
import { InterviewsPage } from './pages/InterviewsPage';
import { LoginPage } from './pages/LoginPage';
import { NotFoundPage } from './pages/NotFoundPage';

const MANAGERS = ['ADMIN', 'INTERVIEWER'];

/**
 * Route table.
 *
 * Candidate-facing routes (`/interviews`, `/interviews/:id`) are open to every authenticated role
 * because the API scopes a CANDIDATE to their own interviews. Management routes are restricted here
 * as well, so a candidate is never shown a screen whose every request would 403.
 */
export function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/forbidden" element={<ForbiddenPage />} />

      <Route element={<ProtectedRoute />}>
        <Route element={<AppLayout />}>
          <Route index element={<Navigate to="/interviews" replace />} />

          <Route path="/interviews" element={<InterviewsPage />} />
          <Route path="/interviews/:id" element={<InterviewDetailPage />} />

          <Route element={<ProtectedRoute roles={MANAGERS} />}>
            <Route path="/dashboard" element={<DashboardPage />} />
            <Route path="/candidates" element={<CandidatesPage />} />
            <Route path="/candidates/new" element={<CandidateFormPage />} />
            <Route path="/candidates/:id" element={<CandidateDetailPage />} />
            <Route path="/candidates/:id/edit" element={<CandidateFormPage />} />
            <Route path="/interviews/new" element={<InterviewFormPage />} />
            <Route path="/interviews/:id/edit" element={<InterviewFormPage />} />
          </Route>

          <Route path="*" element={<NotFoundPage />} />
        </Route>
      </Route>
    </Routes>
  );
}
