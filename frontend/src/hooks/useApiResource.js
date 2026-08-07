/**
 * Loads data from the API and tracks the three states a caller has to distinguish: loading, loaded,
 * failed.
 *
 * Two details that would otherwise be repeated (and forgotten) in every page:
 *
 *  - the result of a superseded request is discarded, so typing quickly in a search box cannot leave
 *    an earlier response overwriting a later one;
 *  - state is never set after unmount, which is where React's "update on unmounted component"
 *    warnings come from.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { describeError, requestIdOf } from '../api/client';

export function useApiResource(loader, dependencies = [], { skip = false } = {}) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(!skip);
  const [error, setError] = useState(null);

  // Incremented per request; a response whose token is stale is ignored.
  const requestToken = useRef(0);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const reload = useCallback(async () => {
    if (skip) {
      setLoading(false);
      return;
    }
    const token = ++requestToken.current;
    setLoading(true);
    setError(null);
    try {
      const response = await loader();
      if (mounted.current && token === requestToken.current) {
        setData(response.data);
      }
    } catch (caught) {
      if (mounted.current && token === requestToken.current) {
        setError({ message: describeError(caught), requestId: requestIdOf(caught), raw: caught });
      }
    } finally {
      if (mounted.current && token === requestToken.current) {
        setLoading(false);
      }
    }
    // `loader` is intentionally excluded: callers pass an inline arrow, so including it would
    // re-run on every render. The dependency array supplied by the caller is the real trigger.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [skip, ...dependencies]);

  useEffect(() => {
    reload();
  }, [reload]);

  return { data, loading, error, reload, setData };
}
