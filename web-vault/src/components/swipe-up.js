// The media viewer's swipe up (MediaLightbox.jsx): a mostly vertical drag upward. No JSX, so tests can import it.

/** Whether a touch from `a` to `b` is a swipe up: at least `min` px up, and more up than sideways (paging is sideways). */
export const swipedUp = (a, b, min = 70) => a.y - b.y >= min && Math.abs(b.x - a.x) < (a.y - b.y) * 0.6
