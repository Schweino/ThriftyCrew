export const BROWSER_STORES = Object.freeze(["aldi", "fareway", "sams", "walmart"]);

/**
 * Run one isolated browser lane per retailer. Each lane owns its own tab,
 * adapter lease, pacing, and challenge lifecycle; a blocked or failed store is
 * reported without cancelling the other retailers.
 *
 * openTab must return { tab, owned }. Only run-owned tabs are closed here.
 */
export async function runBrowserStoreFanout(lanes) {
  if (!Array.isArray(lanes) || lanes.length === 0) return [];
  const stores = lanes.map((lane) => String(lane?.store ?? ""));
  if (new Set(stores).size !== stores.length) throw new Error("browser fanout requires at most one lane per store");
  for (const store of stores) {
    if (!BROWSER_STORES.includes(store)) throw new Error(`unsupported browser lane ${store}`);
  }

  return Promise.all(lanes.map(async (lane) => {
    let handle;
    let result;
    try {
      handle = await lane.openTab();
      if (!handle?.tab) throw new Error(`${lane.store} browser lane did not return a tab`);
      const value = await lane.run(handle.tab);
      result = { store: lane.store, status: "fulfilled", value };
    } catch (error) {
      result = { store: lane.store, status: "rejected", reason: error instanceof Error ? error : new Error(String(error)) };
    } finally {
      if (handle?.owned === true) {
        try { await lane.closeTab(handle.tab); }
        catch (error) {
          const cleanupError = error instanceof Error ? error : new Error(String(error));
          if (result?.status === "rejected") result.cleanupError = cleanupError;
          else result = { store: lane.store, status: "rejected", reason: cleanupError, cleanupFailed: true };
        }
      }
    }
    return result;
  }));
}
