import SwiftUI
import AppKit

/// Manages a floating transparent window that displays a purple arrow
/// pointing at the menu bar relay icon during setup completion.
@MainActor
class FloatingArrowController {
    static let shared = FloatingArrowController()
    private var arrowWindow: NSWindow?

    private let arrowWidth: CGFloat = 220
    private let arrowHeight: CGFloat = 110

    func show() {
        guard arrowWindow == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: arrowWidth, height: arrowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: FloatingArrowView())

        positionBelowMenuBarIcon(window)

        window.alphaValue = 0
        window.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }

        arrowWindow = window
    }

    private func positionBelowMenuBarIcon(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }

        let menuBarThickness = NSStatusBar.system.thickness // ~22pt

        // Find the status item window that belongs to our app.
        // Status item buttons live in small windows pinned to the top of the screen.
        if let iconCenter = findStatusItemCenter(on: screen, menuBarThickness: menuBarThickness) {
            let x = iconCenter - arrowWidth / 2
            let y = screen.frame.maxY - menuBarThickness - arrowHeight
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            // Fallback: place near the right side of the menu bar where status items live
            let x = screen.frame.maxX - 250 - arrowWidth / 2
            let y = screen.frame.maxY - menuBarThickness - arrowHeight
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    /// Scan app windows to find the status item button sitting in the menu bar.
    private func findStatusItemCenter(on screen: NSScreen, menuBarThickness: CGFloat) -> CGFloat? {
        let screenTop = screen.frame.maxY

        for window in NSApp.windows {
            // The most reliable way is checking the private class name used for status buttons
            if String(describing: type(of: window)) == "NSStatusBarWindow" {
                return window.frame.midX
            }

            // Fallback heuristic if internals change
            let f = window.frame
            let isMenuBarHeight = f.height <= menuBarThickness + 15 // Relaxed to handle notch/variable heights
            let isAtTop = f.maxY >= screenTop - 10
            let isNarrow = f.width < 100 // Increased to handle icons with text

            if isMenuBarHeight && isAtTop && isNarrow && window.alphaValue > 0 {
                return f.midX
            }
        }

        return nil
    }

    func dismiss() {
        guard let window = arrowWindow else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                window.orderOut(nil)
                self?.arrowWindow = nil
            }
        })
    }
}

// MARK: - Arrow View

struct FloatingArrowView: View {
    @State private var floating = false
    @State private var appeared = false
    @State private var glowPulse = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.havenPurpleLight, .havenPurple],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .shadow(color: .havenPurple.opacity(glowPulse ? 0.8 : 0.25), radius: glowPulse ? 18 : 6)
                .offset(y: floating ? -6 : 6)

            Text("Your relay lives here")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.havenPurple, .havenPurpleDark],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .havenPurple.opacity(0.4), radius: 8)
                )
        }
        .scaleEffect(appeared ? 1.0 : 0.15)
        .opacity(appeared ? 1.0 : 0.0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.5)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                floating = true
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}
