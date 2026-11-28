import Cocoa
import CoreGraphics

@MainActor
final class WindowTracker {
    private let state: HUDState
    private weak var panel: HUDPanel?
    private weak var monitor: TranscriptMonitor?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var geometryTimer: Timer?
    private var hostScanTimer: Timer?
    private var isDraggingPanel = false

    /// App whose window the panel is docked to: Antigravity, or a terminal hosting agy.
    private var dockTarget: NSRunningApplication?
    private var lastDockedRect: NSRect?
    private var lastDockedPid: pid_t = 0
    private var lastDockedWindowNumber: Int = 0
    private var cliHostPids: Set<pid_t> = []

    private let antigravityBundleIds: Set<String> = ["com.google.antigravity"]

    init(state: HUDState, panel: HUDPanel, monitor: TranscriptMonitor) {
        self.state = state
        self.panel = panel
        self.monitor = monitor
        installObservers()
        evaluateVisibilityAndPosition(forceSnap: true)
    }

    deinit {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        geometryTimer?.invalidate()
        hostScanTimer?.invalidate()
    }

    func setDragging(_ dragging: Bool) {
        isDraggingPanel = dragging
        if !dragging, let panel, let hostRect = currentDockRect() {
            let clamped = clampOrigin(panel.frame.origin, size: panel.frame.size, referenceRect: hostRect)
            if abs(clamped.x - panel.frame.origin.x) > 0.5 || abs(clamped.y - panel.frame.origin.y) > 0.5 {
                panel.setFrameOrigin(clamped)
            }
            lastDockedRect = hostRect
            lastDockedPid = dockTarget?.processIdentifier ?? 0
            let dxFromRight = Double(panel.frame.maxX - hostRect.maxX)
            let dyFromTop = Double(panel.frame.maxY - hostRect.maxY)
            let onDesktop = isDockedToAntigravity
            state.updatePrefs { prefs in
                if onDesktop {
                    prefs.customOffsetX = dxFromRight
                    prefs.customOffsetY = dyFromTop
                } else {
                    prefs.cliOffsetX = dxFromRight
                    prefs.cliOffsetY = dyFromTop
                }
            }
        }
    }

    func snapToRightEdge() {
        let onDesktop = isDockedToAntigravity
        state.updatePrefs { prefs in
            if onDesktop {
                prefs.customOffsetX = nil
                prefs.customOffsetY = nil
            } else {
                prefs.cliOffsetX = nil
                prefs.cliOffsetY = nil
            }
        }
        evaluateVisibilityAndPosition(forceSnap: true)
    }

    func setUserHidden(_ hidden: Bool) {
        state.userHidden = hidden
        evaluateVisibilityAndPosition(forceSnap: false)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        state.updatePrefs { prefs in
            prefs.alwaysOnTop = enabled
        }
        evaluateVisibilityAndPosition(forceSnap: false)
    }

    func evaluateVisibilityAndPosition(forceSnap: Bool = false) {
        cliHostPids = AgentProcessScanner.cliHostPids()

        let front = NSWorkspace.shared.frontmostApplication
        let frontIsSelf = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let frontSources = front.map { sources(hostedBy: $0) } ?? []

        let shouldShow: Bool
        if state.userHidden {
            shouldShow = false
        } else if state.alwaysOnTop {
            shouldShow = true
        } else {
            shouldShow = !frontSources.isEmpty || frontIsSelf
        }

        if state.isVisible != shouldShow {
            state.isVisible = shouldShow
            monitor?.updatePollingCadence()
        }

        if let front, !frontSources.isEmpty {
            dockTarget = front
            monitor?.setFocusContext(
                sources: frontSources,
                hostPid: front.processIdentifier,
                isHostFrontmost: true
            )
        } else if let current = dockTarget, !current.isTerminated, !sources(hostedBy: current).isEmpty {
            // Keep following the last host while another app (or the HUD itself) is in front.
            let hostStillFront = frontIsSelf ? (monitor?.isFocusHostFrontmost ?? false) : false
            monitor?.setFocusHostPid(current.processIdentifier, isHostFrontmost: hostStillFront)
        } else {
            dockTarget = fallbackDockTarget()
            monitor?.setFocusHostPid(dockTarget?.processIdentifier, isHostFrontmost: false)
        }

        guard let panel else { return }
        if shouldShow {
            positionPanel(panel, forceSnap: forceSnap)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            ensureGeometryTimerRunning()
        } else {
            if panel.isVisible {
                panel.orderOut(nil)
            }
            stopGeometryTimer()
        }
    }

    private func installObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if name == NSWorkspace.didActivateApplicationNotification {
                        AgentProcessScanner.invalidateCache()
                    }
                    self?.evaluateVisibilityAndPosition(forceSnap: false)
                }
            }
            workspaceObservers.append(token)
        }

        // Starting or quitting agy in a terminal that is already frontmost raises no
        // workspace notification, so the set of hosting terminals is re-read on a timer.
        hostScanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AgentProcessScanner.cliHostPids() != self.cliHostPids {
                    self.evaluateVisibilityAndPosition(forceSnap: false)
                } else if self.state.isVisible {
                    self.monitor?.updatePollingCadence()
                }
            }
        }
    }

    private func ensureGeometryTimerRunning() {
        guard geometryTimer == nil else { return }
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state.isVisible, !self.isDraggingPanel, let panel = self.panel else { return }
                self.positionPanel(panel, forceSnap: false)
            }
        }
    }

    private func stopGeometryTimer() {
        geometryTimer?.invalidate()
        geometryTimer = nil
    }

    // MARK: - Host apps

    private func isAntigravity(_ app: NSRunningApplication) -> Bool {
        if let bundleId = app.bundleIdentifier {
            if antigravityBundleIds.contains(bundleId) { return true }
            if bundleId.contains("helper") { return false }
        }
        return app.localizedName == "Antigravity"
    }

    /// Which front ends `app` is showing, limited to the ones the user chose to track.
    private func sources(hostedBy app: NSRunningApplication) -> Set<AgentSource> {
        var result: Set<AgentSource> = []
        if isAntigravity(app), state.sourceMode != .cli {
            result.insert(.desktop)
        }
        if cliHostPids.contains(app.processIdentifier), state.sourceMode != .desktop {
            result.insert(.cli)
        }
        return result
    }

    private func fallbackDockTarget() -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        if state.sourceMode != .cli, let desktop = running.first(where: { isAntigravity($0) }) {
            return desktop
        }
        if state.sourceMode != .desktop {
            return running.first { cliHostPids.contains($0.processIdentifier) }
        }
        return nil
    }

    private var isDockedToAntigravity: Bool {
        dockTarget.map { isAntigravity($0) } ?? true
    }

    private func currentDockWindow() -> (rect: NSRect, windowNumber: Int)? {
        guard let app = dockTarget, !app.isTerminated, !app.isHidden else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Antigravity is docked by its main (largest) window. A terminal usually has
        // several similar windows, so there the frontmost one is the session in use;
        // the window list is ordered front to back.
        let preferLargest = isAntigravity(app)

        // Quartz coordinates have origin at top-left of the primary display.
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900.0
        var bestWindow: (rect: NSRect, windowNumber: Int)?
        var bestArea: CGFloat = 0

        for win in list {
            guard let ownerPid = win[kCGWindowOwnerPID as String] as? Int32, ownerPid == pid else { continue }
            let layer = (win[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }
            guard let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            guard cgRect.width > 200 && cgRect.height > 200 else { continue }
            let windowNumber = (win[kCGWindowNumber as String] as? Int) ?? 0
            let appKitY = primaryScreenHeight - cgRect.origin.y - cgRect.height
            let rect = NSRect(x: cgRect.origin.x, y: appKitY, width: cgRect.width, height: cgRect.height)
            if !preferLargest {
                return (rect, windowNumber)
            }
            let area = cgRect.width * cgRect.height
            if area > bestArea {
                bestArea = area
                bestWindow = (rect, windowNumber)
            }
        }
        return bestWindow
    }

    private func currentDockRect() -> NSRect? {
        currentDockWindow()?.rect
    }

    private func positionPanel(_ panel: HUDPanel, forceSnap: Bool) {
        let size = panel.frame.size
        guard size.width > 0, size.height > 0 else { return }

        if let dockWindow = currentDockWindow() {
            let hostRect = dockWindow.rect
            let hostPid = dockTarget?.processIdentifier ?? 0
            let windowChanged = (hostPid == lastDockedPid && dockWindow.windowNumber != 0 && dockWindow.windowNumber != lastDockedWindowNumber)
            if windowChanged {
                lastDockedWindowNumber = dockWindow.windowNumber
                monitor?.handleHostWindowChanged()
            } else if hostPid != lastDockedPid || lastDockedWindowNumber == 0 {
                lastDockedWindowNumber = dockWindow.windowNumber
            }
            if !forceSnap, hostPid == lastDockedPid, let prev = lastDockedRect,
               abs(prev.origin.x - hostRect.origin.x) < 1.0,
               abs(prev.origin.y - hostRect.origin.y) < 1.0,
               abs(prev.size.width - hostRect.size.width) < 1.0,
               abs(prev.size.height - hostRect.size.height) < 1.0 {
                return
            }
            lastDockedRect = hostRect
            lastDockedPid = hostPid

            // Defaults clear Antigravity's toolbar, and a terminal's title/tab bar.
            let dx: Double
            let dy: Double
            if isDockedToAntigravity {
                dx = state.prefs.customOffsetX ?? -14.0
                dy = state.prefs.customOffsetY ?? -62.0
            } else {
                dx = state.prefs.cliOffsetX ?? -14.0
                dy = state.prefs.cliOffsetY ?? -44.0
            }
            var origin = NSPoint(
                x: hostRect.maxX + dx - size.width,
                y: hostRect.maxY + dy - size.height
            )
            origin = clampOrigin(origin, size: size, referenceRect: hostRect)
            panel.setFrameOrigin(origin)
        } else if forceSnap || lastDockedRect == nil {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = NSPoint(
                x: visible.maxX - size.width - 14,
                y: visible.maxY - size.height - 14
            )
            panel.setFrameOrigin(origin)
        }
    }

    func clampOrigin(_ origin: NSPoint, size: NSSize, referenceRect: NSRect? = nil) -> NSPoint {
        let hostRect = referenceRect ?? currentDockRect()
        let screen: NSScreen?
        if let ref = hostRect {
            screen = NSScreen.screens.max(by: {
                $0.frame.intersection(ref).area < $1.frame.intersection(ref).area
            }) ?? NSScreen.main ?? NSScreen.screens.first
        } else {
            screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main ?? NSScreen.screens.first
        }

        if let hostRect {
            let bounds: NSRect
            if let visible = screen?.visibleFrame {
                let intersected = hostRect.intersection(visible)
                bounds = (!intersected.isNull && intersected.width >= 80 && intersected.height >= 40) ? intersected : hostRect
            } else {
                bounds = hostRect
            }
            let inset: CGFloat = 8
            let minX = bounds.minX + inset
            let maxX = max(minX, bounds.maxX - size.width - inset)
            let minY = bounds.minY + inset
            let maxY = max(minY, bounds.maxY - size.height - inset)
            return NSPoint(
                x: min(max(origin.x, minX), maxX),
                y: min(max(origin.y, minY), maxY)
            )
        }

        guard let visible = screen?.visibleFrame else { return origin }
        let minX = visible.minX + 6
        let maxX = max(minX, visible.maxX - size.width - 6)
        let minY = visible.minY + 6
        let maxY = max(minY, visible.maxY - size.height - 6)
        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull && !isEmpty else { return 0 }
        return width * height
    }
}
