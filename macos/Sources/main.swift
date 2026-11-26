import Cocoa
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: HUDState!
    private var quotaClient: QuotaClient!
    private var monitor: TranscriptMonitor!
    private var panel: HUDPanel!
    private var windowTracker: WindowTracker!
    private var statusBar: StatusBarController!
    private var ipcServer: HookIPCServer!
    private var quotaTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDataDir()

        let hudState = HUDState()
        self.state = hudState

        let quota = QuotaClient(state: hudState)
        self.quotaClient = quota

        let transcriptMonitor = TranscriptMonitor(state: hudState, quotaClient: quota)
        self.monitor = transcriptMonitor

        let rootView = HUDView(
            state: hudState,
            onRefreshQuota: { [weak quota] in
                quota?.refresh(force: true)
            },
            onExpandQuota: { [weak quota] in
                quota?.refresh(force: false)
            },
            onToggleMiniPill: { [weak hudState] in
                hudState?.updatePrefs { prefs in
                    prefs.miniPill.toggle()
                }
            },
            onSizeChange: { [weak self] size in
                guard let self, let panel = self.panel, let tracker = self.windowTracker else { return }
                panel.updateSize(width: size.width, height: size.height) { origin, targetSize in
                    tracker.clampOrigin(origin, size: targetSize)
                }
            }
        )

        let hudPanel = HUDPanel(rootView: rootView, cornerRadius: hudState.isMiniPill ? 17 : 14)
        self.panel = hudPanel

        hudState.$isMiniPill
            .receive(on: DispatchQueue.main)
            .sink { [weak hudPanel] isMiniPill in
                hudPanel?.setCornerRadius(isMiniPill ? 17 : 14)
            }
            .store(in: &cancellables)

        let tracker = WindowTracker(state: hudState, panel: hudPanel, monitor: transcriptMonitor)
        self.windowTracker = tracker
        hudPanel.onDragStateChanged = { [weak tracker] dragging in
            tracker?.setDragging(dragging)
        }
        hudPanel.constrainOrigin = { [weak tracker] origin, size in
            tracker?.clampOrigin(origin, size: size) ?? origin
        }

        self.statusBar = StatusBarController(
            state: hudState,
            windowTracker: tracker,
            monitor: transcriptMonitor,
            quotaClient: quota
        )

        let ipc = HookIPCServer { [weak self] msg in
            guard let self else { return }
            self.quotaClient.updateCredentials(lsAddress: msg.lsAddress, csrfToken: msg.csrfToken)
            self.monitor.handleHookEvent(msg)
            self.windowTracker.evaluateVisibilityAndPosition(forceSnap: false)
            if msg.event == "SessionStart" || msg.event == "PreInvocation" || msg.event == "Stop" {
                self.quotaClient.refresh(force: false)
            }
        }
        self.ipcServer = ipc
        ipc.start()

        transcriptMonitor.start()

        quotaTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state.isVisible else { return }
                self.quotaClient.refresh(force: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.invalidate()
        monitor?.stop()
        ipcServer?.stop()
    }
}

// Single-instance guard so concurrent hook launches never spawn duplicate HUDs
let currentPid = ProcessInfo.processInfo.processIdentifier
if let bid = Bundle.main.bundleIdentifier {
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .filter { $0.processIdentifier != currentPid }
    if !existing.isEmpty {
        exit(0)
    }
}

let delegate = MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    return delegate
}
_ = delegate
NSApplication.shared.run()
