# Haven App v2.5.1 (macOS) / v1.1.1 (iOS) Release Notes

This update introduces major performance and experience enhancements to media feeds and full-screen video playback across macOS, iOS, and iPadOS. We have resolved critical gesture swallowing bugs, redesigned full-screen video controls with high-fidelity glassmorphic overlays, and optimized playback transitions via shared players.

> [!IMPORTANT]
> **Performance Tip**: When viewing videos in the feed, you can now tap once to open full-screen playback instantly, or long-press (0.5s) to view the note's detail tree. Tapping inside the full-screen player also supports native hardware keyboard shortcuts on iPad and macOS!

## Key Features & Improvements

*   **Shared Video Player Cache (`VideoPlayerCache`)**: Implemented a size-limited LRU pool (up to 10 instances) of `AVPlayer`. Inline feed playback now transitions seamlessly into full-screen without stopping or restarting the track, preserving the exact current playhead.
*   **Premium Glassmorphic Playback Controls**: Built a stunning, floating controls console utilizing an `.ultraThinMaterial` pill with a soft reflective border. Features a high-fidelity seek scrubber, monospace timecode display, play/pause and mute/unmute buttons.
*   **iPad & Wide-Screen Scaling**: The floating media controls panel automatically adapts, centers, and scales dynamically on large canvas screens and landscape devices.
*   **Hardware Keyboard Mappings**: Standardized desktop/iPad hardware keys inside the media viewer—press **Spacebar** to toggle play/pause, **M** to mute/unmute, and **Left / Right Arrow Keys** to skip 5 seconds backward/forward.
*   **Buffer Thumbnail Overlays**: Eliminated empty black boxes during video initialization by overlaying static thumbnails that fade out smoothly once the active player frame starts rendering.
*   **Grid Navigation & Swipe Carousel**: Tapping media cells launches a swipeable, full-screen horizontal paging view (`TabView`) populated by a static snapshot (`gridMediaSnapshot`) captured at tap-time, safeguarding your swiping position against background feed syncs.

## Bug Fixes & Refinement

*   **Gesture Conflict Resolution**: Resolved native `AVPlayerLayer` gesture capturing issues by bypassing hit-testing on the core layer. This allows scroll and drag-to-dismiss gestures to flow seamlessly to parent SwiftUI views.
*   **Horizontal Media Swiping**: Restricted the drag-to-dismiss gesture inside the full-screen `FeedMediaViewer` to the vertical axis when unzoomed. This prevents visual conflicts and enables smooth, native horizontal swiping between images and videos in the sheet carousel.
*   **Video Swiping & Tap-to-Pause**: Placed an `.allowsHitTesting(false)` overlay on the native full-screen video layer and paired it with a transparent tap-capturing ZStack, allowing swipes to bubble up natively to the paging container while preserving play/pause tapping.
*   **Global Feed Sensitive Content Warning**: Overhauled warning flow to display a Sensitive Content Warning confirmation dialog every single time the user clicks or switches to the Global Media Feed, enforcing continuous compliance.
*   **Horizontal Swipe Carousel Dismissal**: Fixed sheet presentation conflict in `FeedView` where horizontal swiping triggered immediate page dismiss-and-reappear animations, by transitioning the sheet container to be presented via a simple boolean `isShowingGridMediaViewer` rather than the active selection's identity.
*   **Conditional Tap Event Swallowing**: Standardized dynamic touch handling with a custom `.onTapGestureIfSome` helper, ensuring standard cell interaction is preserved without intercepting parent lists.
*   **Full-Screen Video Aspect Ratio**: Fixed aspect ratio calculation inside `FullScreenVideoPlayer` by replacing generic fill bounds with `.resizeAspect` (letterbox) to render wide videos perfectly, while keeping `.resizeAspectFill` for inline feed cards.
*   **Blossom Mirroring Spec Compliance**: Aligned authorization HTTP headers with the canonical BUD-02 standard using the correct `Nostr` token prefix, standardizing JSON response parsing, and enabling trust bypass for local Tailscale/LAN IP ranges.
*   **NIP-18 Reposts Formatting**: Standardized kind 6 repost publication structure to stringify root event contents inside `content` and attach correct `e`/`p` markers.
*   **Account Switching Safety**: Prevented flight crosstalk and visual corruption during active account shifts by discarding pending contact lists and background relay requests dynamically.

Thank you for being part of the Haven community!
