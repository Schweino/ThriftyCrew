import { describe, expect, it, vi } from "vitest";
import { BROWSER_STORES, runBrowserStoreFanout } from "./browser-store-fanout.mjs";

describe("browser store fanout", () => {
  it("starts all four isolated store lanes before any one completes", async () => {
    const started = [];
    const releases = new Map();
    const closes = [];
    const pending = runBrowserStoreFanout(BROWSER_STORES.map((store) => ({
      store,
      openTab: async () => ({ tab: { store }, owned: true }),
      run: async () => new Promise((resolve) => { started.push(store); releases.set(store, resolve); }),
      closeTab: async (tab) => { closes.push(tab.store); },
    })));
    await vi.waitFor(() => expect(started).toHaveLength(4));
    for (const store of BROWSER_STORES) releases.get(store)(`${store}-done`);
    await expect(pending).resolves.toEqual(BROWSER_STORES.map((store) => ({ store, status: "fulfilled", value: `${store}-done` })));
    expect(closes).toEqual(expect.arrayContaining(BROWSER_STORES));
  });

  it("keeps other stores running when one store is challenged", async () => {
    const closed = [];
    const results = await runBrowserStoreFanout([
      { store: "aldi", openTab: async () => ({ tab: "aldi-tab", owned: true }), run: async () => { throw new Error("ALDI challenge"); }, closeTab: async (tab) => closed.push(tab) },
      { store: "walmart", openTab: async () => ({ tab: "walmart-tab", owned: true }), run: async () => "captured", closeTab: async (tab) => closed.push(tab) },
    ]);
    expect(results[0]).toMatchObject({ store: "aldi", status: "rejected", reason: expect.objectContaining({ message: "ALDI challenge" }) });
    expect(results[1]).toEqual({ store: "walmart", status: "fulfilled", value: "captured" });
    expect(closed).toEqual(expect.arrayContaining(["aldi-tab", "walmart-tab"]));
  });

  it("never closes a user-owned tab", async () => {
    const closeTab = vi.fn();
    await runBrowserStoreFanout([{ store: "sams", openTab: async () => ({ tab: "existing", owned: false }), run: async () => "ok", closeTab }]);
    expect(closeTab).not.toHaveBeenCalled();
  });

  it("rejects duplicate store lanes before opening tabs", async () => {
    const openTab = vi.fn();
    await expect(runBrowserStoreFanout([
      { store: "fareway", openTab },
      { store: "fareway", openTab },
    ])).rejects.toThrow("at most one lane per store");
    expect(openTab).not.toHaveBeenCalled();
  });
});
