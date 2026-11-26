// Settings › Media & Cache › Upload Quality (Logen 2026-11-26, RESEARCH/NV_UPLOAD_COMPRESSION_2026_11_26.md §6, plan
// W2): one setting, no switch on each attachment, as Apple's UploadQuality (#2567) and Android's (#2561).
// - "standard" (the default): photos you post, send in live chat or in a DM are shrunk (net/image-compress.js).
// - "original": they go up as they are.
// The location is removed either way (media-privacy.js). Vault › Media always uploads originals and doesn't read this;
// covers, listings and profile photos keep their own sizes. Kept in this browser; read at each upload.
const KEY = "media.uploadQuality"
export const STANDARD = "standard"
export const ORIGINAL = "original"

/** The saved choice; anything unknown is Standard. */
export function uploadQuality(storage = globalThis.localStorage) {
  try { return storage?.getItem?.(KEY) === ORIGINAL ? ORIGINAL : STANDARD } catch { return STANDARD }
}
export function setUploadQuality(value, storage = globalThis.localStorage) {
  try { storage?.setItem?.(KEY, value === ORIGINAL ? ORIGINAL : STANDARD) } catch {}
}

export const UPLOAD_QUALITY_CHOICES = [{ value: STANDARD, label: "Standard" }, { value: ORIGINAL, label: "Original" }]
/** The words under the choice (MediaUploadQualitySettingsView's rows; no video line: the web sends videos as they are). */
export const uploadQualityNote = v => (v === ORIGINAL
  ? "Photos go up as they are. Bigger files, and some media servers refuse large ones."
  : "Photos up to 2048 px. Smaller files that upload and load faster.")
export const UPLOAD_QUALITY_FOOTER = "For notes, live chat and messages. Location is removed either way. Vault › Media always keeps the original."
