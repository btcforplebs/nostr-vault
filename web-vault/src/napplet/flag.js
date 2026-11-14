// Napplets in the app's own screens (plan P2 on): off unless switched on from the napplet shell page (/vault/?shell=1).
// While off, each screen keeps its old panel (the plan's "old screen stays behind a switch for one release").
const KEY = "nv-napplets"
export const nappletsOn = (store = globalThis.localStorage) => { try { return store?.getItem(KEY) === "1" } catch { return false } }
export const setNappletsOn = (on, store = globalThis.localStorage) => { try { on ? store.setItem(KEY, "1") : store.removeItem(KEY) } catch {} }
