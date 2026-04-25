import AppKit
import Combine

/// Bridges AppKit's NSScreen state into a published array of
/// `RoamScreen` that `RoamingController` consumes. Also tracks which
/// screen currently contains the cursor so the buddy can be summoned to
/// the right monitor.
@MainActor
final class ScreenManager: ObservableObject {
    @Published private(set) var screens: [RoamScreen] = []
    @Published private(set) var cursorScreenID: Int = 0

    private var screenChangeObserver: NSObjectProtocol?
    private var cursorTicker: Timer?

    init() {
        refresh()
    }

    /// Start observing screen-change notifications and polling the
    /// cursor position. Call once from AppDelegate at launch.
    func start() {
        refresh()

        if screenChangeObserver == nil {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }

        if cursorTicker == nil {
            cursorTicker = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateCursorScreen() }
            }
        }
    }

    func stop() {
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenChangeObserver = nil
        }
        cursorTicker?.invalidate()
        cursorTicker = nil
    }

    // MARK: - Private

    private func refresh() {
        screens = NSScreen.screens.enumerated().map { index, s in
            RoamScreen(id: index, frame: s.frame)
        }
    }

    private func updateCursorScreen() {
        let loc = NSEvent.mouseLocation
        cursorScreenID = screens.first(where: { $0.frame.contains(loc) })?.id ?? 0
    }
}
