import AppKit
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "BuddyWindow")

/// Transparent borderless NSPanel that hosts the pixel buddy.
///
/// Mouse events are handled at the window level so we can use AppKit's
/// native `performDrag` for smooth hardware-accelerated window moves
/// (SwiftUI's DragGesture visibly flickered at 60fps against our own
/// roaming ticker).
///
/// A left mouse-down triggers a drag session that blocks until the user
/// releases. After it returns, we compare the start origin to the end
/// origin — zero movement means the user just clicked, which routes to
/// `onClick`; non-zero means they dragged, which routes to `onDragEnded`.
final class BuddyWindow: NSPanel {
    /// Fired at left-mouse-down so AppDelegate can suspend roaming.
    var onMouseDown: (() -> Void)?

    /// Fired after the drag session completes. `wasDrag` is false when
    /// the user clicked without moving — AppDelegate treats that as a
    /// request to open the session list bubble.
    var onMouseUp: ((_ wasDrag: Bool) -> Void)?

    /// Mouse position in screen coordinates at mouseDown. Used with
    /// NSEvent.mouseLocation inside mouseDragged to compute a live delta
    /// and reposition the window.
    private var dragStartMouseScreen: NSPoint?
    private var dragStartWindowOrigin: CGPoint?

    init(size: CGSize) {
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
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // NSPanel.performDrag silently returns on .nonactivatingPanel, so
    // we drive the drag manually with mouseDown → mouseDragged → mouseUp
    // using screen-space mouse deltas. Window-space coords drift with
    // the window during the drag, so we have to use NSEvent.mouseLocation
    // (which is the raw screen position).

    override func mouseDown(with event: NSEvent) {
        dragStartMouseScreen = NSEvent.mouseLocation
        dragStartWindowOrigin = frame.origin
        onMouseDown?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouseScreen,
              let startOrigin = dragStartWindowOrigin else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        setFrameOrigin(CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let startOrigin = dragStartWindowOrigin ?? frame.origin
        let wasDrag = frame.origin != startOrigin
        dragStartMouseScreen = nil
        dragStartWindowOrigin = nil
        logger.debug("mouseUp — wasDrag=\(wasDrag)")
        onMouseUp?(wasDrag)
    }

    /// Move the window's top-left origin (AppKit screen coordinates).
    func place(at point: CGPoint) {
        setFrameOrigin(point)
    }
}
