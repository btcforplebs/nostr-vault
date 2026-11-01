/** What the picker, a drop or a paste may attach: photos and videos (ComposeView+Attachments), nothing else. */
export const isMedia = f => /^(image|video)\//.test(f?.type ?? "")
export const isVideo = m => /^video\//.test(m?.mime ?? m?.type ?? m?.file?.type ?? "")
