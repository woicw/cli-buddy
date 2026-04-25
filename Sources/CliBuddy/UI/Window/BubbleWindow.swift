import AppKit
import SwiftUI

/// Floating panel that hosts SwiftUI bubble content (approval / question /
/// session list). Positions itself next to the buddy and shadows the
/// content so it reads against the desktop.
///
/// Generic over the content view so AppDelegate can swap ApprovalBubbleView
/// / QuestionBubbleView / SessionListBubbleView without subclassing.
final class BubbleWindow<Content: View>: NSPanel {
    /// Horizontal gap between the buddy and the bubble, in points.
    var horizontalGap: CGFloat = 12
    /// Padding from the screen's visible edges so the bubble never
    /// hugs the menu bar or dock.
    var edgePadding: CGFloat = 8

    init(size: CGSize, rootView: Content) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        // BubbleChrome paints its own shadow; a system shadow would
        // halo the transparent NSPanel's bounding rect and look wrong.
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.contentView = NSHostingView(rootView: rootView)
    }

    /// Show the bubble anchored next to the buddy's frame (AppKit screen
    /// coordinates). Places the bubble on the same screen as the buddy,
    /// top-aligned with the buddy's top, to the right by default. Flips
    /// to the left when that would spill past the right edge; clamps the
    /// vertical position to the buddy's screen.
    func present(nextTo buddyFrame: CGRect, on screen: NSScreen? = nil) {
        let buddyCenter = CGPoint(x: buddyFrame.midX, y: buddyFrame.midY)
        let targetScreen = screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(buddyCenter) })
            ?? NSScreen.main
        let visible = targetScreen?.visibleFrame ?? .zero

        // Horizontal: to the right of the buddy, flipping left if it
        // would cross the right edge.
        var x = buddyFrame.maxX + horizontalGap
        if x + self.frame.width > visible.maxX - edgePadding {
            x = buddyFrame.minX - horizontalGap - self.frame.width
        }
        // If flipping still leaves it off-screen (tiny display), clamp.
        x = max(visible.minX + edgePadding,
                min(x, visible.maxX - self.frame.width - edgePadding))

        // Vertical: align the bubble's top with the buddy's top so the
        // bubble grows downward from a fixed anchor, then clamp to the
        // screen so tall bubbles don't spill past the bottom.
        var y = buddyFrame.maxY - self.frame.height
        y = max(visible.minY + edgePadding,
                min(y, visible.maxY - self.frame.height - edgePadding))

        setFrameOrigin(CGPoint(x: x, y: y))
        orderFront(nil)
    }

    /// Replace the SwiftUI root so the same window can host different
    /// bubble types over its lifetime.
    func swap(rootView: Content) {
        if let host = contentView as? NSHostingView<Content> {
            host.rootView = rootView
        } else {
            contentView = NSHostingView(rootView: rootView)
        }
    }

    /// Anchor the bubble just below a menu-bar status item button. Used
    /// by the usage panel so it reads like the system's own menu popovers.
    func present(below statusItem: NSStatusItem) {
        guard let button = statusItem.button,
              let buttonWindow = button.window else {
            orderFront(nil)
            return
        }
        let screenFrame = buttonWindow.convertToScreen(button.frame)
        let x = screenFrame.midX - self.frame.width / 2
        let y = screenFrame.minY - self.frame.height - 4
        // Clamp to the current screen so the bubble doesn't flow off
        // the left or right edge on short menu bars.
        let bounds = NSScreen.main?.visibleFrame ?? .infinite
        let clampedX = min(max(x, bounds.minX + 4), bounds.maxX - self.frame.width - 4)
        setFrameOrigin(CGPoint(x: clampedX, y: y))
        orderFront(nil)
    }
}
