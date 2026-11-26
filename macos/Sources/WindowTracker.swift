import Cocoa
import CoreGraphics

@MainActor
final class WindowTracker {
    private let state: HUDState
    private weak var panel: HUDPanel?
    private weak var monitor: TranscriptMonitor?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var geometryTimer: Timer?
    private var lastDockedAntigravityRect: NSRect?
    private var isDraggingPanel = false

    private let targetBundleIds: Set<String> = ["com.google.antigravity"]

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
    }

    func setDragging(_ dragging: Bool) {
        isDraggingPanel = dragging
        if !dragging, let panel, let agyRect = currentAntigravityAppKitRect() {
            let clamped = clampOrigin(panel.frame.origin, size: panel.frame.size, referenceRect: agyRect)
            if abs(clamped.x - panel.frame.origin.x) > 0.5 || abs(clamped.y - panel.frame.origin.y) > 0.5 {
                panel.setFrameOrigin(clamped)
            }
            lastDockedAntigravityRect = agyRect
            let dxFromRight = Double(panel.frame.maxX - agyRect.maxX)
            let dyFromTop = Double(panel.frame.maxY - agyRect.maxY)
            state.updatePrefs { prefs in
                prefs.customOffsetX = dxFromRight
                prefs.customOffsetY = dyFromTop
            }
        }
    }

    func snapToRightEdge() {
        state.updatePrefs { prefs in
            prefs.customOffsetX = nil
            prefs.customOffsetY = nil
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
        let shouldShow: Bool
        if state.userHidden {
            shouldShow = false
        } else if state.alwaysOnTop {
            shouldShow = true
        } else {
            shouldShow = isAntigravityOrSelfFrontmost()
        }

        if state.isVisible != shouldShow {
            state.isVisible = shouldShow
            monitor?.updatePollingCadence()
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
                    self?.evaluateVisibilityAndPosition(forceSnap: false)
                }
            }
            workspaceObservers.append(token)
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

    private func isAntigravityOrSelfFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let bundleId = front.bundleIdentifier {
            if targetBundleIds.contains(bundleId) || bundleId == Bundle.main.bundleIdentifier {
                return true
            }
        }
        if let name = front.localizedName, name == "Antigravity" {
            return true
        }
        return false
    }

    private func findAntigravityApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            if let bid = app.bundleIdentifier, targetBundleIds.contains(bid) {
                return true
            }
            return app.localizedName == "Antigravity" && !(app.bundleIdentifier?.contains("helper") ?? false)
        }
    }

    private func currentAntigravityAppKitRect() -> NSRect? {
        guard let app = findAntigravityApp(), !app.isHidden else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Quartz coordinates have origin at top-left of the primary display.
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900.0
        var bestRect: NSRect?
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
            let area = cgRect.width * cgRect.height
            if area > bestArea {
                bestArea = area
                let appKitY = primaryScreenHeight - cgRect.origin.y - cgRect.height
                bestRect = NSRect(x: cgRect.origin.x, y: appKitY, width: cgRect.width, height: cgRect.height)
            }
        }
        return bestRect
    }

    private func positionPanel(_ panel: HUDPanel, forceSnap: Bool) {
        let size = panel.frame.size
        guard size.width > 0, size.height > 0 else { return }

        if let agyRect = currentAntigravityAppKitRect() {
            if !forceSnap, let prev = lastDockedAntigravityRect,
               abs(prev.origin.x - agyRect.origin.x) < 1.0,
               abs(prev.origin.y - agyRect.origin.y) < 1.0,
               abs(prev.size.width - agyRect.size.width) < 1.0,
               abs(prev.size.height - agyRect.size.height) < 1.0 {
                return
            }
            lastDockedAntigravityRect = agyRect

            let dx = state.prefs.customOffsetX ?? -14.0
            let dy = state.prefs.customOffsetY ?? -62.0
            var origin = NSPoint(
                x: agyRect.maxX + dx - size.width,
                y: agyRect.maxY + dy - size.height
            )
            origin = clampOrigin(origin, size: size, referenceRect: agyRect)
            panel.setFrameOrigin(origin)
        } else if forceSnap || lastDockedAntigravityRect == nil {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = NSPoint(
                x: visible.maxX - size.width - 14,
                y: visible.maxY - size.height - 14
            )
            panel.setFrameOrigin(origin)
        }
    }

    func clampOrigin(_ origin: NSPoint, size: NSSize, referenceRect: NSRect? = nil) -> NSPoint {
        let agyRect = referenceRect ?? currentAntigravityAppKitRect()
        let screen: NSScreen?
        if let ref = agyRect {
            screen = NSScreen.screens.max(by: {
                $0.frame.intersection(ref).area < $1.frame.intersection(ref).area
            }) ?? NSScreen.main ?? NSScreen.screens.first
        } else {
            screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main ?? NSScreen.screens.first
        }

        if let agyRect {
            let bounds: NSRect
            if let visible = screen?.visibleFrame {
                let intersected = agyRect.intersection(visible)
                bounds = (!intersected.isNull && intersected.width >= 80 && intersected.height >= 40) ? intersected : agyRect
            } else {
                bounds = agyRect
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
