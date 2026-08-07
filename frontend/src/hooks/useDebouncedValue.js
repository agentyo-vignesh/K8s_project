import { useEffect, useState } from 'react';

/**
 * Delays propagating a rapidly changing value.
 *
 * Used for search inputs: without it, every keystroke is a request, which turns a five-character
 * search into five queries the server has to run and four responses the UI throws away.
 */
export function useDebouncedValue(value, delayMs = 300) {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delayMs);
    // Clearing on change is what makes it a debounce rather than a queue of delayed updates.
    return () => clearTimeout(timer);
  }, [value, delayMs]);

  return debounced;
}
