import Cocoa
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let state: HUDState
    private let windowTracker: WindowTracker
    private let monitor: TranscriptMonitor
    private let quotaClient: QuotaClient

    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(
        state: HUDState,
        windowTracker: WindowTracker,
        monitor: TranscriptMonitor,
        quotaClient: QuotaClient
    ) {
        self.state = state
        self.windowTracker = windowTracker
        self.monitor = monitor
        self.quotaClient = quotaClient
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateButtonTitle()
        bindState()
    }

    private func bindState() {
        Publishers.CombineLatest3(state.$contextTokens, state.$lastTurnTps, state.$isGenerating)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.updateButtonTitle()
            }
            .store(in: &cancellables)
    }

    private func updateButtonTitle() {
        guard let button = statusItem.button else { return }
        let symbolName = state.isGenerating ? "bolt.circle.fill" : "gauge.with.dots.needle.67percent"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AgyHUD")
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeading

        if state.contextTokens > 0 {
            let ctx = HUDFormatters.formatTokens(state.contextTokens)
            button.title = " \(ctx)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        } else {
            button.title = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let summary = NSMenuItem(
            title: "\(state.activeSource.badge) · \(state.modelDisplayName) · \(HUDFormatters.formatTokens(state.contextTokens)) · \(HUDFormatters.formatTps(state.lastTurnTps)) tok/s",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let toggleVis = NSMenuItem(title: "显示悬浮窗", action: #selector(toggleVisible), keyEquivalent: "")
        toggleVis.target = self
        toggleVis.state = state.userHidden ? .off : .on
        menu.addItem(toggleVis)

        let togglePill = NSMenuItem(title: "迷你药丸模式", action: #selector(toggleMiniPill), keyEquivalent: "")
        togglePill.target = self
        togglePill.state = state.isMiniPill ? .on : .off
        menu.addItem(togglePill)

        let followFront = NSMenuItem(title: "仅 Antigravity / agy 终端在前台时显示", action: #selector(toggleFollowFront), keyEquivalent: "")
        followFront.target = self
        followFront.state = state.alwaysOnTop ? .off : .on
        menu.addItem(followFront)

        let snapItem = NSMenuItem(title: "吸附到窗口右上角", action: #selector(snapRight), keyEquivalent: "")
        snapItem.target = self
        menu.addItem(snapItem)

        let themeMenuItem = NSMenuItem(title: "外观主题", action: nil, keyEquivalent: "")
        let themeSubmenu = NSMenu()
        for theme in HUDTheme.allCases {
            let item = NSMenuItem(title: theme.menuTitle, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = state.theme == theme ? .on : .off
            themeSubmenu.addItem(item)
        }
        themeMenuItem.submenu = themeSubmenu
        menu.addItem(themeMenuItem)

        menu.addItem(.separator())

        let quotaVisibleAndExpanded = state.isQuotaExpanded && !state.isMiniPill && !state.userHidden
        let quotaToggle = NSMenuItem(
            title: quotaVisibleAndExpanded ? "折叠配额面板" : "展开配额面板",
            action: #selector(toggleQuota),
            keyEquivalent: ""
        )
        quotaToggle.target = self
        menu.addItem(quotaToggle)

        let refreshQuotaItem = NSMenuItem(title: "立即刷新配额", action: #selector(refreshQuota), keyEquivalent: "")
        refreshQuotaItem.target = self
        menu.addItem(refreshQuotaItem)

        menu.addItem(.separator())

        let sourceMenuItem = NSMenuItem(title: "数据来源", action: nil, keyEquivalent: "")
        let sourceSubmenu = NSMenu()
        let autoSourceItem = NSMenuItem(title: "自动（跟随前台窗口）", action: #selector(selectSourceMode(_:)), keyEquivalent: "")
        autoSourceItem.target = self
        autoSourceItem.state = state.sourceMode == nil ? .on : .off
        sourceSubmenu.addItem(autoSourceItem)
        for source in AgentSource.allCases {
            let item = NSMenuItem(title: "仅 \(source.menuTitle)", action: #selector(selectSourceMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            item.state = state.sourceMode == source ? .on : .off
            sourceSubmenu.addItem(item)
        }
        sourceMenuItem.submenu = sourceSubmenu
        menu.addItem(sourceMenuItem)

        let convMenuItem = NSMenuItem(title: "跟踪对话", action: nil, keyEquivalent: "")
        let convSubmenu = NSMenu()
        let autoItem = NSMenuItem(title: "自动跟随活跃对话", action: #selector(selectAutoConversation), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = state.pinnedConversationId == nil ? .on : .off
        convSubmenu.addItem(autoItem)
        if !state.recentConversations.isEmpty {
            convSubmenu.addItem(.separator())
            for conv in state.recentConversations {
                let title = conv.source == .cli ? "[CLI] \(conv.title)" : conv.title
                let item = NSMenuItem(title: title, action: #selector(selectSpecificConversation(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = conv.id
                item.state = state.pinnedConversationId == conv.id ? .on : .off
                convSubmenu.addItem(item)
            }
        }
        convMenuItem.submenu = convSubmenu
        menu.addItem(convMenuItem)

        let autoLaunchItem = NSMenuItem(title: "随 Antigravity / agy 自动启动", action: #selector(toggleAutoLaunch), keyEquivalent: "")
        autoLaunchItem.target = self
        autoLaunchItem.state = state.autoLaunch ? .on : .off
        menu.addItem(autoLaunchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 AgyHUD", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleVisible() {
        windowTracker.setUserHidden(!state.userHidden)
    }

    @objc private func toggleMiniPill() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.state.userHidden {
                self.windowTracker.setUserHidden(false)
            }
            self.state.updatePrefs { prefs in
                prefs.miniPill.toggle()
            }
        }
    }

    @objc private func toggleFollowFront() {
        windowTracker.setAlwaysOnTop(!state.alwaysOnTop)
    }

    @objc private func snapRight() {
        windowTracker.setUserHidden(false)
        windowTracker.snapToRightEdge()
    }

    @objc private func toggleQuota() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let currentlyShowingExpanded = self.state.isQuotaExpanded && !self.state.isMiniPill && !self.state.userHidden
            if currentlyShowingExpanded {
                self.state.isQuotaExpanded = false
            } else {
                if self.state.userHidden {
                    self.windowTracker.setUserHidden(false)
                }
                if self.state.isMiniPill {
                    self.state.updatePrefs { prefs in
                        prefs.miniPill = false
                    }
                }
                self.state.isQuotaExpanded = true
                self.quotaClient.refresh(force: false)
            }
        }
    }

    @objc private func refreshQuota() {
        quotaClient.refresh(force: true)
    }

    @objc private func selectAutoConversation() {
        monitor.selectConversation(nil)
    }

    @objc private func selectSpecificConversation(_ sender: NSMenuItem) {
        if let convId = sender.representedObject as? String {
            monitor.selectConversation(convId)
        }
    }

    @objc private func selectSourceMode(_ sender: NSMenuItem) {
        let mode = (sender.representedObject as? String).flatMap { AgentSource(rawValue: $0) }
        state.updatePrefs { prefs in
            prefs.sourceMode = mode
        }
        monitor.updatePollingCadence()
        monitor.refreshNow(scanConversations: true)
        windowTracker.evaluateVisibilityAndPosition(forceSnap: false)
    }

    @objc private func toggleAutoLaunch() {
        state.updatePrefs { prefs in
            prefs.autoLaunch.toggle()
        }
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = HUDTheme(rawValue: raw) else { return }
        state.updatePrefs { prefs in
            prefs.theme = theme
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
