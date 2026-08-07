/**
 * Every API call the UI makes, in one place.
 *
 * Components never build a URL or touch Axios directly. One consequence that matters: the API's
 * versioned prefix lives in `config.js`, so moving to `/api/v2` is one change here rather than a
 * search across every page.
 */
import { apiClient } from './client';

export const authApi = {
  login: (email, password) => apiClient.post('/auth/login', { email, password }),
  refresh: (refreshToken) => apiClient.post('/auth/refresh', { refreshToken }),
  logout: (refreshToken) => apiClient.post('/auth/logout', { refreshToken }),
  me: () => apiClient.get('/auth/me'),
};

export const candidateApi = {
  /** `params` accepts search, status, primarySkill, minExperience, page, size and sort. */
  search: (params) => apiClient.get('/candidates', { params }),
  findById: (id) => apiClient.get(`/candidates/${id}`),
  create: (payload) => apiClient.post('/candidates', payload),
  update: (id, payload) => apiClient.put(`/candidates/${id}`, payload),
  remove: (id) => apiClient.delete(`/candidates/${id}`),
};

export const resumeApi = {
  listForCandidate: (candidateId) => apiClient.get(`/candidates/${candidateId}/resumes`),

  upload: (candidateId, file, onProgress) => {
    const form = new FormData();
    form.append('file', file);
    return apiClient.post(`/candidates/${candidateId}/resumes`, form, {
      // Content-Type is deliberately unset: the browser must add the multipart boundary itself, and
      // overriding it with 'multipart/form-data' produces a body the server cannot parse.
      headers: { 'Content-Type': undefined },
      timeout: 60000,
      onUploadProgress: (event) => {
        if (onProgress && event.total) {
          onProgress(Math.round((event.loaded * 100) / event.total));
        }
      },
    });
  },

  /** Returns a Blob; the caller turns it into a download. */
  download: (resumeId) => apiClient.get(`/resumes/${resumeId}/download`, { responseType: 'blob' }),

  remove: (resumeId) => apiClient.delete(`/resumes/${resumeId}`),
};

export const interviewApi = {
  search: (params) => apiClient.get('/interviews', { params }),
  findById: (id) => apiClient.get(`/interviews/${id}`),
  create: (payload) => apiClient.post('/interviews', payload),
  update: (id, payload) => apiClient.put(`/interviews/${id}`, payload),
  assignInterviewer: (id, interviewerId) =>
    apiClient.patch(`/interviews/${id}/interviewer`, { interviewerId }),
  updateStatus: (id, status) => apiClient.patch(`/interviews/${id}/status`, { status }),
  remove: (id) => apiClient.delete(`/interviews/${id}`),
  listQuestions: (id) => apiClient.get(`/interviews/${id}/questions`),

  /** Generation calls through to the AI service, so it needs a longer ceiling than the default. */
  generateQuestions: (id, payload) =>
    apiClient.post(`/interviews/${id}/questions/generate`, payload, { timeout: 90000 }),

  findResult: (id) => apiClient.get(`/interviews/${id}/result`),
  submitResult: (id, payload) => apiClient.post(`/interviews/${id}/result`, payload),
};

export const dashboardApi = {
  summary: () => apiClient.get('/dashboard/summary'),
};

export const userApi = {
  listByRole: (role = 'INTERVIEWER') => apiClient.get('/users', { params: { role } }),
};

/**
 * Saves a Blob response as a file download.
 *
 * The object URL is revoked afterwards; without that, every download leaks the whole file for the
 * lifetime of the tab.
 */
export function triggerBlobDownload(blob, filename) {
  const url = window.URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  window.URL.revokeObjectURL(url);
}
