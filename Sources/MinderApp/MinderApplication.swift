import AppKit
import Combine
import SwiftUI
import MinderCore

final class MinderApplication: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private static var retainedDelegate: MinderApplication?
    private static let backgroundSyncInterval: TimeInterval = 15 * 60
    private static let popoverWidth: CGFloat = 760
    private static let queuePopoverHeight: CGFloat = 620
    private static let settingsPopoverHeight: CGFloat = queuePopoverHeight

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var syncTimer: Timer?
    private var viewModel: MinderViewModel?
    private var store: MinderStore?
    private var permissionService: MacPermissionService?
    private var settingsViewModel: OnboardingViewModel?
    private var queueWindow: NSWindow?
    private var selectedTabCancellable: AnyCancellable?
    private var queueItemsCancellable: AnyCancellable?

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
                alertNotifier: NudgeUserNotificationService()
            )
            model.showQueueWindow = { [weak self] in
                Task { @MainActor in
                    self?.showQueueWindow()
                }
            }
            model.isQueueInterfaceVisible = { [weak self] in
                guard let self else { return false }
                return (self.popover?.isShown ?? false) || (self.queueWindow?.isVisible ?? false)
            }
            viewModel = model

            let settingsModel = makeSettingsViewModel(
                store: store,
                permissionService: permissionService,
                messagesImporter: messagesImporter
            )
            settingsViewModel = settingsModel

            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = popoverContentSize(for: model)
            popover.contentViewController = NSHostingController(rootView: InboxView(model: model, settingsModel: settingsModel))
            self.popover = popover

            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = NudgeSymbolImage.menuBarTemplate()
            statusItem.button?.target = self
            statusItem.button?.action = #selector(togglePopover)
            self.statusItem = statusItem
            updateStatusItemTitle()
            selectedTabCancellable = model.$selectedTab
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.updatePopoverContentSize()
                    }
                }
            queueItemsCancellable = model.$queueItems
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.updatePopoverContentSize()
                    }
                }
            model.refresh()
            model.refreshPermissionHealth()
            if model.profile?.hasCompletedOnboarding != true {
                model.openSetup()
                showPopover()
            } else {
                startBackgroundSync()
            }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    @MainActor
    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @MainActor
    private func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        updatePopoverContentSize()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func updatePopoverContentSize() {
        guard let popover, let viewModel else { return }
        popover.contentSize = popoverContentSize(for: viewModel)
    }

    @MainActor
    private func popoverContentSize(for model: MinderViewModel) -> NSSize {
        let requestedHeight: CGFloat
        switch model.selectedTab {
        case .queue, .done:
            requestedHeight = Self.queuePopoverHeight
        case .settings:
            requestedHeight = Self.settingsPopoverHeight
        }

        let visibleHeight = NSScreen.main?.visibleFrame.height ?? requestedHeight
        let cappedHeight = min(requestedHeight, max(420, visibleHeight - 96))
        return NSSize(width: Self.popoverWidth, height: cappedHeight)
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
            },
            onChange: { [weak self] in
                self?.viewModel?.refresh()
            }
        )
    }

    @MainActor
    private func showQueueWindow() {
        if let queueWindow {
            queueWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let viewModel, let settingsViewModel else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nudge Queue"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: InboxView(model: viewModel, settingsModel: settingsViewModel))
        window.delegate = self
        queueWindow = window

        window.makeKeyAndOrderFront(nil)
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

    func applicationWillTerminate(_ notification: Notification) {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}

extension MinderApplication: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === queueWindow {
            queueWindow = nil
        }
    }
}
