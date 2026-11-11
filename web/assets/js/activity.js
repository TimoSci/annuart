// Click-based activity brightness, the pure part. A history is a list of
// activity ids, most recently clicked first. An area's brightness is how near
// the front of that list it is: one step dimmer per click on something else,
// never per unit of time. Ids only: no amounts, no addresses of other people.
export const STEPS = 8;
export const MAX_ITEMS = 50;

export function touch(history, id) {
  return [id, ...history.filter(x => x !== id)].slice(0, MAX_ITEMS);
}

export function level(history, id) {
  const index = history.indexOf(id);
  return index < 0 ? 0 : Math.max(0, 1 - index / STEPS);
}

export function storageFor({chainId, address} = {}) {
  if (!address) return {area: "session", key: "annuart:activity:session"};
  return {area: "local", key: `annuart:activity:${chainId}:${String(address).toLowerCase()}`};
}

// Storage may be missing, blocked, full or hold something else: the page
// works without it.
export function load(storage, key) {
  try {
    const parsed = JSON.parse(storage.getItem(key));
    return Array.isArray(parsed) ? parsed.filter(x => typeof x === "string").slice(0, MAX_ITEMS) : [];
  } catch {
    return [];
  }
}

export function save(storage, key, history) {
  try {
    storage.setItem(key, JSON.stringify(history));
  } catch {
    // unavailable or full: the history lives on in memory for this page
  }
}
