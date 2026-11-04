// Picture-in-picture for a <video> (PiP plan lane D): the browser API, kept apart from PipButton.jsx for tests.

/** Whether `video` can go into picture-in-picture in this browser. */
export const canPiP = (video, doc = globalThis.document) =>
  !!doc?.pictureInPictureEnabled && typeof video?.requestPictureInPicture === "function" && !video?.disablePictureInPicture

/** Into PiP, or out of it when `video` is the one in PiP now. -> the browser's promise. */
export function togglePiP(video, doc = globalThis.document) {
  if (doc?.pictureInPictureElement === video) return doc.exitPictureInPicture()
  return video.requestPictureInPicture()
}

