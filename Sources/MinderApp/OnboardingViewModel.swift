import Combine
import AppKit
import Foundation
import MinderCore

@MainActor
final class OnboardingViewModel: ObservableObject {
    let managedAI: ManagedAISettingsModel
    @Published var profile: UserProfile
    @Published private(set) var permissionHealth: [PermissionHealth] = []
    @Published private(set) var sources: [ConversationSource] = []
    @Published private(set) var lastImportResults: [SourceKind: ImportResult] = [:]
#if NUDGE_INTERNAL_DIAGNOSTICS
    @Published private(set) var appleMessagesTextDiagnostics: AppleMessagesTextDiagnostics?
    @Published private(set) var appleMessagesDecodeTraceReport: AppleMessagesDecodeTraceReport?
#endif
    @Published var selectedStep: OnboardingStep = .welcome
    @Published var statusMessage: String = "Setup is ready."
    @Published var geminiAPIKeyInput: String = ""
    @Published var geminiModelInput: String = "gemini-2.5-flash"
    @Published var isWorking = false

    private let store: MinderStore
    private let coordinator: OnboardingPermissionCoordinator
    private let messagesImporter: AppleMessagesConversationImporter
    private let geminiConfigStore: GeminiConfigStore
    private let onComplete: @MainActor () -> Void
    private let onChange: @MainActor () -> Void

    init(
        store: MinderStore,
        permissionService: PermissionServicing,
        messagesImporter: AppleMessagesConversationImporter = AppleMessagesConversationImporter(),
        geminiConfigStore: GeminiConfigStore = GeminiConfigStore(),
        onComplete: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.managedAI = ManagedAISettingsModel(store: store, onChange: onChange)
        self.store = store
        self.coordinator = OnboardingPermissionCoordinator(store: store, service: permissionService)
        self.messagesImporter = messagesImporter
        self.geminiConfigStore = geminiConfigStore
        self.onComplete = onComplete
        self.onChange = onChange
        self.profile = (try? store.fetchUserProfile()) ?? UserProfile(displayName: NSFullUserName())
        self.permissionHealth = (try? store.fetchPermissionHealth()) ?? []
        self.sources = (try? store.fetchSources()) ?? []
        self.loadGeminiConfigInputs()
    }

    var hasGeminiConfig: Bool {
        geminiConfigValidation.isValid
    }

    var geminiConfigValidation: GeminiConfigValidationResult {
        GeminiConfigValidationResult.validate(savedGeminiConfig)
    }

    var geminiInputValidation: GeminiConfigValidationResult {
        GeminiConfigValidationResult.validate(GeminiConfig(
            apiKey: geminiAPIKeyInput,
            model: geminiModelInput.nilIfEmpty ?? "gemini-2.5-flash"
        ))
    }

    var geminiConfigNeedsSave: Bool {
        guard geminiInputValidation.isValid else {
            return false
        }
        let saved = savedGeminiConfig
        let inputKey = geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputModel = geminiModelInput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "gemini-2.5-flash"
        return saved?.apiKey != inputKey || saved?.model != inputModel
    }

    var canSaveGeminiConfig: Bool {
        !geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canMoveBack: Bool {
        selectedStep != onboardingSteps.first
    }

    var canMoveForward: Bool {
        selectedStep != onboardingSteps.last
    }

    var completedPermissionCount: Int {
        permissionHealth.filter { $0.state == .available }.count
    }

    var messagesReadiness: OnboardingReadinessState {
        if health(for: .fullDiskAccess).state != .available {
            return .needsPermission
        }
        if source(for: .appleMessages)?.lastSyncAt != nil {
            return .imported
        }
        if health(for: .appleMessages).state == .available {
            return .ready
        }
        return .needsSetup
    }

    var contactsReadiness: OnboardingReadinessState {
        switch health(for: .contacts).state {
        case .available:
            return .connected
        case .missing:
            return .ready
        case .revoked:
            return .needsPermission
        case .degraded, .unsupported:
            return .needsSetup
        }
    }

    var canImportMessages: Bool {
        health(for: .fullDiskAccess).state == .available && health(for: .appleMessages).state == .available
    }

    var canRequestContacts: Bool {
        health(for: .contacts).state != .available
    }

    var operationalStatus: NudgeOperationalStatus {
        NudgeOperationalStatus.make(
            profile: profile,
            permissionHealth: permissionHealth,
            sources: sources,
            lastRefreshFailed: false,
            hasCloudAIConfig: hasGeminiConfig
        )
    }

    var settingsSteps: [OnboardingStep] {
        [.about, .status, .messages, .notifications, .privacy, .cloudAI, .appearance, .profile]
    }

    var onboardingSteps: [OnboardingStep] {
        [.about, .status, .messages, .notifications, .privacy, .cloudAI, .summary]
    }

    var messagesNextAction: String? {
        switch messagesReadiness {
        case .needsPermission:
            return "Grant Full Disk Access to Nudge, then return here and click Check Again."
        case .needsSetup:
            return health(for: .appleMessages).detail
        case .ready:
            return "Access is ready. Import recent Messages to add this source to Nudge."
        case .connected:
            return nil
        case .imported:
            return "Apple Messages has imported at least once. You can import again to refresh recent messages."
        }
    }

    var contactsNextAction: String? {
        switch contactsReadiness {
        case .ready:
            return "Optional but recommended. Contacts lets Nudge replace phone numbers and emails with local contact names."
        case .connected:
            return "Contacts are available. The next Messages import will use local names when possible."
        case .needsPermission:
            return "Contacts were denied. You can re-enable them in System Settings, or keep importing with phone/email fallback."
        case .needsSetup:
            return health(for: .contacts).detail
        case .imported:
            return nil
        }
    }

    func load() {
        do {
            profile = try store.fetchUserProfile() ?? UserProfile(displayName: NSFullUserName())
            permissionHealth = try store.fetchPermissionHealth()
            sources = try store.fetchSources()
            loadGeminiConfigInputs()
            if permissionHealth.isEmpty {
                refreshPermissions()
            }
        } catch {
            statusMessage = "Setup load failed: \(error.localizedDescription)"
        }
    }

    func health(for kind: PermissionKind) -> PermissionHealth {
        permissionHealth.first { $0.kind == kind } ?? PermissionHealth(
            kind: kind,
            state: .missing,
            detail: "\(kind.displayName) has not been checked yet."
        )
    }

    func source(for kind: SourceKind) -> ConversationSource? {
        sources.first { $0.kind == kind }
    }

    func next() {
        saveProfile()
        guard let index = onboardingSteps.firstIndex(of: selectedStep), index < onboardingSteps.count - 1 else {
            return
        }
        selectedStep = onboardingSteps[index + 1]
    }

    func back() {
        saveProfile()
        guard let index = onboardingSteps.firstIndex(of: selectedStep), index > 0 else {
            return
        }
        selectedStep = onboardingSteps[index - 1]
    }

    func saveProfile() {
        do {
            try store.saveUserProfile(profile)
            onChange()
        } catch {
            statusMessage = "Profile save failed: \(error.localizedDescription)"
        }
    }

    func completeOnboarding() {
        perform("Completing setup...") {
            if self.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.profile.displayName = NSFullUserName()
            }
            self.profile.completedOnboardingAt = Date()
            try self.store.saveUserProfile(self.profile)
            self.permissionHealth = try await self.refreshAllHealth()
            self.sources = try self.store.fetchSources()
            self.statusMessage = "Setup complete."
            self.onChange()
            self.onComplete()
        }
    }

    func refreshPermissions() {
        perform("Checking permissions...") {
            self.permissionHealth = try await self.refreshAllHealth()
            self.sources = try self.store.fetchSources()
            self.statusMessage = "Permission health refreshed."
            self.onChange()
        }
    }

    func refreshSourceHealth() {
        perform("Checking source health...") {
            self.permissionHealth = try await self.refreshAllHealth()
            self.sources = try self.store.fetchSources()
            self.statusMessage = "Source health refreshed."
            self.onChange()
        }
    }

    func request(_ kind: PermissionKind) {
        perform("Requesting \(kind.displayName)...") {
            let health = try await self.coordinator.request(kind)
            self.replaceHealth(health)
            self.statusMessage = self.statusMessage(for: health)
            self.onChange()
        }
    }

    func importMessagesRecent() {
        perform("Importing recent Messages...") {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
            let result = try await self.messagesImporter.importRecent(into: self.store, since: cutoff)
            self.lastImportResults[.appleMessages] = result
            self.permissionHealth = try await self.refreshAllHealth()
            self.sources = try self.store.fetchSources()
            let generated = try await self.generateStoredSuggestions()
            self.statusMessage = "Messages imported \(result.insertedMessages) messages; skipped \(result.skippedMessages). Updated \(generated) suggestions."
            self.onChange()
        }
    }

    func saveGeminiConfig() {
        perform("Saving Gemini setup...") {
            let validation = self.geminiInputValidation
            guard let config = validation.config else {
                self.statusMessage = validation.userFacingMessage
                return
            }

            try self.geminiConfigStore.save(config)
            self.permissionHealth = try await self.refreshAllHealth()
            self.statusMessage = "Saved Gemini setup."
            self.onChange()
        }
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    func runAppleMessagesTextDiagnostic() {
        perform("Checking Messages text storage...") {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
            let diagnostics = try self.messagesImporter.textDiagnostics(since: cutoff)
            self.appleMessagesTextDiagnostics = diagnostics
            self.statusMessage = "Messages text check complete: \(diagnostics.recoveredOutgoingWithoutPlainTextCount) sent rows can be recovered; \(diagnostics.outgoingUnresolvedAfterDecode) still need another decoder."
        }
    }

    func runAppleMessagesDecodeTrace() {
        perform("Tracing Mom/Hunter Messages decoding...") {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
            let targets = ["Mom", "Hunter", "ksm"]
            let report = try self.messagesImporter.decodeTrace(
                threadTitleMatches: targets,
                aliasesByTitle: appleMessagesDecodeTraceAliases(for: targets, store: self.store),
                since: cutoff,
                limitPerThread: 12
            )
            self.appleMessagesDecodeTraceReport = report
            self.statusMessage = "Messages decode trace complete: \(report.threadMatches.count) chat matches, \(report.outgoingRowCount) sent rows, \(report.placeholderRowCount) placeholders."
        }
    }
#endif

    func clearGeneratedSuggestions() {
        perform("Deleting generated suggestions...") {
            try self.store.deleteSuggestions()
            self.statusMessage = "Deleted generated suggestions."
            self.onChange()
        }
    }

    func clearImportedConversationCache() {
        perform("Deleting imported Messages cache...") {
            try self.store.deleteImportedConversationCache()
            self.sources = try self.store.fetchSources()
            self.statusMessage = "Deleted imported Messages, threads, and generated suggestions. Manual notes and setup were kept."
            self.onChange()
        }
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    func clearGeminiDiagnostics() {
        perform("Clearing Cloud AI diagnostics...") {
            try self.store.clearGeminiDiagnosticRuns()
            self.appleMessagesTextDiagnostics = nil
            self.appleMessagesDecodeTraceReport = nil
            self.statusMessage = "Cleared diagnostics."
            self.onChange()
        }
    }
#endif

    func eraseAllData() {
        perform("Deleting all local Nudge data...") {
            try self.store.eraseAllData()
            self.profile = UserProfile(displayName: NSFullUserName())
            self.permissionHealth = []
            self.sources = []
            self.lastImportResults = [:]
#if NUDGE_INTERNAL_DIAGNOSTICS
            self.appleMessagesTextDiagnostics = nil
            self.appleMessagesDecodeTraceReport = nil
#endif
            self.statusMessage = "Deleted all local Nudge data."
            self.onChange()
        }
    }

    func openSettings(for kind: PermissionKind) {
        perform("Opening System Settings...") {
            let opened = await self.coordinator.openSystemSettings(for: kind)
            if opened, kind == .fullDiskAccess || kind == .appleMessages {
                self.statusMessage = "Opened Full Disk Access. Add or toggle Nudge, then return here and click Check Again."
            } else {
                self.statusMessage = opened ? "Opened System Settings for \(kind.displayName)." : "Could not open System Settings for \(kind.displayName)."
            }
        }
    }

    private func replaceHealth(_ health: PermissionHealth) {
        permissionHealth.removeAll { $0.kind == health.kind }
        permissionHealth.append(health)
        permissionHealth.sort { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func statusMessage(for health: PermissionHealth) -> String {
        if health.kind == .notifications {
            switch health.state {
            case .available:
                return "Notifications are enabled."
            case .missing:
                return "Notifications have not been enabled yet."
            case .revoked:
                return "Notifications are off in System Settings."
            case .degraded, .unsupported:
                return health.detail
            }
        }

        return "\(health.kind.displayName): \(health.state.displayName)."
    }

    private func loadGeminiConfigInputs() {
        guard let config = savedGeminiConfig else { return }
        geminiAPIKeyInput = config.apiKey
        geminiModelInput = config.model
    }

    private var savedGeminiConfig: GeminiConfig? {
        GeminiConfig.fromEnvironment() ?? geminiConfigStore.load()
    }

    private func refreshAllHealth() async throws -> [PermissionHealth] {
        let health = try await coordinator.refresh()
        return health.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func generateStoredSuggestions() async throws -> Int {
        let config = GeminiConfig.fromEnvironment()
        let mode = SuggestionGeneratorFactory.mode(profile: profile, geminiConfig: config)
        do {
            let rankingService = SuggestionGeneratorFactory.makeRankingService(profile: profile, geminiConfig: config)
            let suggestions = try await SuggestionEngine(
                store: store,
                rankingService: rankingService,
                enabledSourceKinds: [.appleMessages]
            ).generateFromStoredMessages()
            return suggestions.count
        } catch where mode == .cloudAI {
            let suggestions = try await SuggestionEngine(
                store: store,
                rankingService: LocalConversationRankingService(),
                enabledSourceKinds: [.appleMessages]
            ).generateFromStoredMessages()
            return suggestions.count
        }
    }

    private func perform(_ message: String, operation: @MainActor @escaping () async throws -> Void) {
        isWorking = true
        statusMessage = message
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                statusMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case status
    case notifications
    case profile
    case appearance
    case messages
    case cloudAI
    case privacy
    case about
    case summary

    static var allCases: [OnboardingStep] {
        return [.welcome, .about, .status, .messages, .notifications, .privacy, .cloudAI, .appearance, .profile, .summary]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .status: return "Status"
        case .notifications: return "Pixel cat"
        case .profile: return "Preferences"
        case .appearance: return "Theme"
        case .messages: return "Messages"
        case .cloudAI: return "AI"
        case .privacy: return "Privacy"
        case .about: return "About"
        case .summary: return "Summary"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: return "sparkles"
        case .status: return "gauge.with.dots.needle.67percent"
        case .notifications: return "pawprint.fill"
        case .profile: return "person.crop.circle"
        case .appearance: return "paintpalette"
        case .messages: return "message"
        case .cloudAI: return "cloud"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        case .summary: return "checkmark.seal"
        }
    }
}

private extension HealthState {
    var displayName: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Missing"
        case .degraded: return "Degraded"
        case .revoked: return "Revoked"
        case .unsupported: return "Unsupported"
        }
    }
}

enum OnboardingReadinessState: String, Equatable {
    case ready = "Ready"
    case needsSetup = "Needs setup"
    case needsPermission = "Needs permission"
    case connected = "Connected"
    case imported = "Imported"
}
