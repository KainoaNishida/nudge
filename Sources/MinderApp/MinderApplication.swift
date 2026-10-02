import AppKit
import Combine
import SwiftUI
import MinderCore

final class MinderApplication: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private static var retainedDelegate: MinderApplication?
    private static let backgroundSyncInterval: TimeInterval = 15 * 60
    private static let queueWindowFrameKey = "nudge.queue-window.frame.v1"
    private static let onboardingWindowFrameKey = "nudge.setup-window.frame.v1"
    private var statusItem: NSStatusItem?
    private var syncTimer: Timer?
    private var viewModel: MinderViewModel?
    private var store: MinderStore?
    private var permissionService: MacPermissionService?
    private var settingsViewModel: OnboardingViewModel?
    private var queueWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var petWindow: PetWindowController?
    private var petTracker = PetAttentionTracker()
    private var petTimer: Timer?
    private var petCardsCancellable: AnyCancellable?
    private var petSettingsCancellable: AnyCancellable?
    private var petLastSignalAt: Date? = UserDefaults.standard.object(forKey: "nudge.pixel-cat.last-signal") as? Date

    static func main() {
        let app = NSApplication.shared
        let delegate = MinderApplication()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try MinderStore()
            let permissionService = MacPermissionService()
            let messagesImporter = AppleMessagesConversationImporter(contactResolver: MacContactResolver())
            self.store = store
            self.permissionService = permissionService

            let model = MinderViewModel(
                store: store,
                permissionService: permissionService,
                messagesImporter: messagesImporter,
                alertNotifier: NudgeNoopAlertNotifier()
            )
            model.showQueueWindow = { [weak self] in
                Task { @MainActor in
                    self?.showQueueWindow()
                }
            }
            model.isQueueInterfaceVisible = { [weak self] in
                guard let self else { return false }
                return (self.onboardingWindow?.isVisible ?? false) || (self.queueWindow?.isVisible ?? false)
            }
            viewModel = model

            let settingsModel = makeSettingsViewModel(
                store: store,
                permissionService: permissionService,
                messagesImporter: messagesImporter
            )
            settingsViewModel = settingsModel

            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = NudgeSymbolImage.menuBarTemplate()
            statusItem.button?.target = self
            statusItem.button?.action = #selector(openMainWindow)
            self.statusItem = statusItem
            updateStatusItemTitle()
            model.refresh()
            petTracker.observe(model.petActionVersions, queueIsVisible: true)
            petWindow = PetWindowController(settings: .shared,
                                            openQueue: { [weak self] in self?.showQueueWindow() },
                                            openSettings: { [weak self] in
                                                self?.viewModel?.selectedTab = .settings
                                                self?.settingsViewModel?.selectedStep = .notifications
                                                self?.showQueueWindow()
                                            })
            petCardsCancellable = model.$suggestionCards.receive(on: RunLoop.main).sink { [weak self] _ in
                Task { @MainActor in self?.observePetQueue() }
            }
            petSettingsCancellable = PetSettings.shared.$options.receive(on: RunLoop.main).sink { [weak self] _ in
                Task { @MainActor in self?.petWindow?.refresh(); self?.maybeSignalPet() }
            }
            petTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.petWindow?.refresh(); self?.maybeSignalPet() }
            }
            model.refreshPermissionHealth()
            if model.profile?.hasCompletedOnboarding != true {
                model.openSetup()
                showOnboardingWindow()
            } else {
                startBackgroundSync()
            }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    @MainActor
    @objc private func openMainWindow() {
        showQueueWindow()
    }

    private func updateStatusItemTitle() {
        statusItem?.button?.title = " Nudge"
        statusItem?.button?.toolTip = "Open Nudge"
    }

    @MainActor
    private func makeSettingsViewModel(
        store: MinderStore,
        permissionService: MacPermissionService,
        messagesImporter: AppleMessagesConversationImporter
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            store: store,
            permissionService: permissionService,
            messagesImporter: messagesImporter,
            onComplete: { [weak self] in
                self?.viewModel?.refresh()
                self?.viewModel?.selectedTab = .queue
                self?.startBackgroundSync()
                self?.onboardingWindow?.close()
                self?.showQueueWindow()
            },
            onChange: { [weak self] in
                self?.viewModel?.refresh()
            }
        )
    }

    @MainActor
    private func showQueueWindow() {
        guard viewModel?.profile?.hasCompletedOnboarding == true else {
            showOnboardingWindow()
            return
        }
        petTracker.acknowledge()
        petWindow?.acknowledge()
        if let queueWindow {
            queueWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let viewModel, let settingsViewModel else { return }
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Nudge Queue"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: InboxView(model: viewModel, settingsModel: settingsViewModel))
        let restoredFrame = restoreFrame(of: window, key: Self.queueWindowFrameKey)
        window.delegate = self
        queueWindow = window

        window.makeKeyAndOrderFront(nil)
        if restoredFrame { restoreFrame(of: window, key: Self.queueWindowFrameKey) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func showOnboardingWindow() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let settingsViewModel else { return }
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Nudge Setup"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: settingsViewModel))
        let restoredFrame = restoreFrame(of: window, key: Self.onboardingWindowFrameKey)
        window.delegate = self
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        if restoredFrame { restoreFrame(of: window, key: Self.onboardingWindowFrameKey) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func startBackgroundSync() {
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: Self.backgroundSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.syncAndGenerateSuggestions(reason: .periodic)
            }
        }
    }

    @MainActor
    @discardableResult
    private func restoreFrame(of window: NSWindow, key: String) -> Bool {
        guard let encoded = UserDefaults.standard.string(forKey: key) else {
            window.center()
            return false
        }
        let saved = NSRectFromString(encoded)
        guard saved.width > 0, saved.height > 0,
              saved.origin.x.isFinite, saved.origin.y.isFinite,
              saved.width.isFinite, saved.height.isFinite,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: saved.midX, y: saved.midY)) })
                ?? NSScreen.main else {
            window.center()
            return false
        }
        let visible = screen.visibleFrame
        let width = min(saved.width, visible.width)
        let height = min(saved.height, visible.height)
        let origin = NSPoint(
            x: min(max(saved.minX, visible.minX), visible.maxX - width),
            y: min(max(saved.minY, visible.minY), visible.maxY - height)
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        return true
    }

    @MainActor
    private func saveFrame(of window: NSWindow, key: String) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }

    @MainActor
    private func observePetQueue() {
        guard let model = viewModel else { return }
        petTracker.observe(model.petActionVersions, queueIsVisible: isQueueInterfaceVisible())
        maybeSignalPet()
    }

    @MainActor
    private func isQueueInterfaceVisible() -> Bool {
        (onboardingWindow?.isVisible ?? false) || (queueWindow?.isVisible ?? false)
    }

    @MainActor
    private func maybeSignalPet() {
        guard !isQueueInterfaceVisible(), PetSettings.shared.isVisibleNow,
              petTracker.shouldSignal(profile: viewModel?.profile, lastSignalAt: petLastSignalAt, now: Date())
        else { return }
        petTracker.acknowledge()
        let now = Date()
        petLastSignalAt = now
        UserDefaults.standard.set(now, forKey: "nudge.pixel-cat.last-signal")
        petWindow?.signal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let queueWindow { saveFrame(of: queueWindow, key: Self.queueWindowFrameKey) }
        if let onboardingWindow { saveFrame(of: onboardingWindow, key: Self.onboardingWindowFrameKey) }
        syncTimer?.invalidate()
        syncTimer = nil
        petTimer?.invalidate()
        petTimer = nil
    }
}

extension MinderApplication: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === queueWindow {
            if let queueWindow { saveFrame(of: queueWindow, key: Self.queueWindowFrameKey) }
            queueWindow = nil
        }
        if notification.object as? NSWindow === onboardingWindow {
            if let onboardingWindow { saveFrame(of: onboardingWindow, key: Self.onboardingWindowFrameKey) }
            onboardingWindow = nil
        }
    }
}
