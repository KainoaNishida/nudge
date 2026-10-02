import Combine
import AppKit
import Foundation
import MinderCore

protocol AppleMessagesImporting {
    func importRecent(into store: MinderStore, since cutoff: Date) async throws -> ImportResult
#if NUDGE_INTERNAL_DIAGNOSTICS
    func textDiagnostics(since cutoff: Date) throws -> AppleMessagesTextDiagnostics
    func decodeTrace(threadTitleMatches: [String], aliasesByTitle: [String: [String]], since cutoff: Date, limitPerThread: Int) throws -> AppleMessagesDecodeTraceReport
#endif
}

extension AppleMessagesConversationImporter: AppleMessagesImporting {}

enum NudgeMainTab: String, CaseIterable, Identifiable {
    case queue
    case done
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue:
            return "Queue"
        case .done:
            return "Done"
        case .settings:
            return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .queue:
            return "checklist"
        case .done:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape"
        }
    }
}

struct NudgeSuggestionCard: Identifiable {
    var suggestion: Suggestion
    var recentMessages: [Message] = []
    var messagePlatform: NudgeMessagePlatform = .unknown
    var messagesURL: URL?
    var managedRecommendation: ThreadRecommendation?

    var id: String {
        suggestion.id
    }
}

enum NudgeMessagePlatform {
    case iMessage
    case smsOrRCS
    case unknown

    init(threadExternalId: String?) {
        let normalized = threadExternalId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.hasPrefix("imessage;") {
            self = .iMessage
        } else if normalized.hasPrefix("sms;") || normalized.hasPrefix("rcs;") {
            self = .smsOrRCS
        } else {
            self = .unknown
        }
    }
}

struct NudgeAlertLegendItem: Identifiable, Equatable {
    var type: SuggestionType
    var count: Int

    var id: SuggestionType {
        type
    }
}

enum NudgeQueueItem: Identifiable {
    case suggestion(NudgeSuggestionCard)
    case manual(ManualQueueItem)

    var id: String {
        switch self {
        case .suggestion(let card):
            return "suggestion:\(card.id)"
        case .manual(let item):
            return "manual:\(item.id)"
        }
    }

    var updatedAt: Date {
        switch self {
        case .suggestion(let card):
            return card.suggestion.updatedAt
        case .manual(let item):
            return item.updatedAt
        }
    }
}

enum NudgeCompletedQueueItem: Identifiable {
    case suggestion(Suggestion)
    case manual(ManualQueueItem)

    var id: String {
        switch self {
        case .suggestion(let suggestion):
            return "suggestion:\(suggestion.id)"
        case .manual(let item):
            return "manual:\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .suggestion(let suggestion):
            return suggestion.evidence.threadTitle
        case .manual(let item):
            return item.title
        }
    }

    var updatedAt: Date {
        switch self {
        case .suggestion(let suggestion):
            return suggestion.completedAt ?? suggestion.updatedAt
        case .manual(let item):
            return item.completedAt ?? item.updatedAt
        }
    }
}

enum NudgeSuggestionSyncReason: Equatable {
    case manual
    case periodic

    var inProgressMessage: String {
        switch self {
        case .manual:
            return "Checking Messages..."
        case .periodic:
            return "Background check in progress..."
        }
    }
}

private struct NudgeAlertIdentity: Hashable {
    var sourceId: String
    var threadId: String
    var type: SuggestionType
    var messageId: String

    init(_ suggestion: Suggestion) {
        sourceId = suggestion.sourceId
        threadId = suggestion.threadId
        type = suggestion.type
        messageId = suggestion.evidence.messageId
    }
}

@MainActor
final class MinderViewModel: ObservableObject {
    @Published var lastManagedActionId: String?
    @Published private(set) var managedState = ManagedLocalState()
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var suggestionCards: [NudgeSuggestionCard] = []
    @Published private(set) var queueItems: [NudgeQueueItem] = []
    @Published private(set) var alertLegendItems: [NudgeAlertLegendItem] = []
    @Published private(set) var activeAlertCount = 0
    @Published private(set) var queuePageIndex = 0
    @Published private(set) var manualItems: [ManualQueueItem] = []
    @Published private(set) var sources: [ConversationSource] = []
    @Published private(set) var threads: [ConversationThread] = []
    @Published private(set) var messages: [Message] = []
    @Published private(set) var auditEvents: [AuditEvent] = []
#if NUDGE_INTERNAL_DIAGNOSTICS
    @Published private(set) var geminiDiagnostics: [GeminiDiagnosticRun] = []
    @Published private(set) var appleMessagesTextDiagnostics: AppleMessagesTextDiagnostics?
    @Published private(set) var appleMessagesDecodeTraceReport: AppleMessagesDecodeTraceReport?
#endif
    @Published private(set) var profile: UserProfile?
    @Published private(set) var permissionHealth: [PermissionHealth] = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastRefreshFailed = false
    @Published var selectedSuggestion: Suggestion?
#if NUDGE_INTERNAL_DIAGNOSTICS
    @Published var isShowingGeminiDiagnostics = false
#endif
    @Published var selectedTab: NudgeMainTab = .queue
    @Published var statusMessage: String = "Ready."
    @Published var isWorking = false
    @Published private(set) var isGeneratingSuggestions = false
    var showQueueWindow: (() -> Void)?
    var isQueueInterfaceVisible: () -> Bool = { false }

    private var managedRefreshRequested = false
    private let store: MinderStore
    private let permissionCoordinator: OnboardingPermissionCoordinator
    private let importer = ConversationImporter()
    private let messagesImporter: any AppleMessagesImporting
    private let alertNotifier: any NudgeAlertNotifying
    private static let prototypeSourceKinds: Set<SourceKind> = [.appleMessages]
    static let queuePageSize = 1
    static let suggestionPreviewMessageLimit = 15
    static let doneVisibleDuration: TimeInterval = 24 * 60 * 60

    init(
        store: MinderStore,
        permissionService: PermissionServicing,
        messagesImporter: any AppleMessagesImporting = AppleMessagesConversationImporter(),
        alertNotifier: any NudgeAlertNotifying = NudgeNoopAlertNotifier()
    ) {
        self.store = store
        self.permissionCoordinator = OnboardingPermissionCoordinator(store: store, service: permissionService)
        self.messagesImporter = messagesImporter
        self.alertNotifier = alertNotifier
    }

    var canGenerateSuggestions: Bool {
        !isGeneratingSuggestions
    }

    var isShowingProgress: Bool {
        isWorking || isGeneratingSuggestions
    }

    var cloudAIStatusText: String {
        managedState.mode == .managed ? managedState.coverage.detail : "Local-only compatibility mode is active."
    }

    var aiModeLabel: String { managedState.mode == .managed ? "Managed AI" : "Local only" }

    var operationalStatus: NudgeOperationalStatus {
        if managedState.mode == .managed {
            return NudgeOperationalStatus(state: managedState.coverage.isComplete ? .ready : .limited, title: managedState.coverage.isComplete ? "Analysis complete" : "Analysis incomplete", detail: managedState.coverage.detail, systemImage: managedState.coverage.isComplete ? "checkmark.circle" : "exclamationmark.circle", targetSettingsStep: .cloudAI)
        }
        return NudgeOperationalStatus.make(
            profile: profile,
            permissionHealth: permissionHealth,
            sources: sources,
            lastRefreshFailed: lastRefreshFailed,
            hasCloudAIConfig: GeminiConfig.fromEnvironment() != nil
        )
    }

    var activeSuggestions: [Suggestion] {
        if managedState.mode == .managed { return managedState.visible().map(managedDisplaySuggestion) }
        return suggestions
            .filter { isPrototypeSuggestion($0) }
            .filter { suggestion in !managedState.threads.values.contains { $0.localThreadId == suggestion.threadId && $0.muted } }
            .filter { $0.state != .completed && $0.state != .dismissed && $0.state != .superseded }
            .sorted(by: isHigherPriorityAlert)
    }

    /// Anonymous revision markers for actionable conversation changes. Text,
    /// names, rank, and presentation wording never enter the pet signal.
    var petActionVersions: [String: String] {
        var versions: [String: String] = [:]
        for suggestion in activeSuggestions where suggestion.state != .snoozed {
            if managedState.mode == .managed {
                guard let rec = managedState.recommendations[suggestion.id], !rec.stale else { continue }
                versions[rec.id] = rec.substantiveRevision
            } else {
                versions[suggestion.id] = suggestion.evidence.messageId
            }
        }
        return versions
    }

    var recentCompletedSuggestions: [Suggestion] {
        let cutoff = Date().addingTimeInterval(-Self.doneVisibleDuration)
        return suggestions
            .filter { isPrototypeSuggestion($0) }
            .filter { $0.state == .completed && ($0.completedAt ?? $0.updatedAt) >= cutoff }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    var activeManualItems: [ManualQueueItem] {
        manualItems
            .filter { $0.state == .active }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeQueueCount: Int {
        activeSuggestions.count + activeManualItems.count
    }

    var queuePageCount: Int {
        guard activeQueueCount > 0 else { return 0 }
        return (activeQueueCount + Self.queuePageSize - 1) / Self.queuePageSize
    }

    var queuePageNumber: Int {
        activeQueueCount > 0 ? queuePageIndex + 1 : 0
    }

    var queuePageRangeText: String {
        guard activeQueueCount > 0 else { return "0 items" }
        let start = queuePageIndex * Self.queuePageSize + 1
        let end = min(activeQueueCount, start + Self.queuePageSize - 1)
        if start == end {
            return "\(start) of \(activeQueueCount)"
        }
        return "\(start)-\(end) of \(activeQueueCount)"
    }

    var canGoToPreviousQueuePage: Bool {
        queuePageIndex > 0
    }

    var canGoToNextQueuePage: Bool {
        queuePageIndex < maxQueuePageIndex(forItemCount: activeQueueCount)
    }

    var recentCompletedQueueItems: [NudgeCompletedQueueItem] {
        let cutoff = Date().addingTimeInterval(-Self.doneVisibleDuration)
        let completedSuggestions = recentCompletedSuggestions.map(NudgeCompletedQueueItem.suggestion)
        let completedManualItems = manualItems
            .filter { $0.state == .completed && ($0.completedAt ?? $0.updatedAt) >= cutoff }
            .map(NudgeCompletedQueueItem.manual)
        return (completedSuggestions + completedManualItems)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var appleMessagesSource: ConversationSource? {
        sources.first { $0.kind == .appleMessages }
    }

    var appleMessagesCount: Int {
        guard let sourceId = appleMessagesSource?.id else { return 0 }
        return messages.filter { $0.sourceId == sourceId }.count
    }

    var needsAttentionCount: Int {
        activeSuggestions.filter { suggestion in
            suggestion.state == .new || suggestion.state == .failed || suggestion.state == .needsPermission || suggestion.confidence >= 0.85
        }.count
    }

    func refresh() {
        let previousItemId = queueItems.first?.id
        let previousGoalRevision = managedState.goal.revision
        do {
            try store.seedLegacyManagedQueue()
            managedState = try store.managedState()
            if managedState.mode == .managed && statusMessage == "Ready." { statusMessage = managedState.coverage.detail }
            profile = try store.fetchUserProfile()
            sources = try store.fetchSources()
            threads = try store.fetchThreads()
            messages = try store.fetchMessages(limit: 200)
            suggestions = try store.fetchSuggestions(includeCompleted: true)
            if managedState.mode == .managed {
                suggestions.removeAll { managedState.recommendations["legacy-" + $0.id] != nil }
                suggestions += managedState.recommendations.values.map(managedDisplaySuggestion)
            }
            manualItems = try store.fetchManualQueueItems(includeCompleted: true)
            auditEvents = try store.fetchAuditEvents(limit: 12)
#if NUDGE_INTERNAL_DIAGNOSTICS
            geminiDiagnostics = try store.fetchGeminiDiagnosticRuns(limit: 20)
#endif
            permissionHealth = try store.fetchPermissionHealth()
            if
                let selected = selectedSuggestion,
                let match = suggestions.first(where: { $0.id == selected.id }),
                isPrototypeSuggestion(match),
                match.state != .completed,
                match.state != .dismissed,
                match.state != .superseded
            {
                selectedSuggestion = match
            } else {
                selectedSuggestion = activeSuggestions.first
            }
            if suggestions.isEmpty && statusMessage == "Ready." {
                statusMessage = messages.isEmpty ? "Refresh to check Messages." : "Refresh Messages for alerts."
            }
            try refreshQueuePresentation(preserving: previousItemId)
            if managedState.mode == .managed && previousGoalRevision != managedState.goal.revision {
                Task { @MainActor in self.syncAndGenerateSuggestions(reason: .manual) }
            }
        } catch {
            lastRefreshFailed = true
            statusMessage = "Refresh failed: \(error.localizedDescription)"
        }
    }

    func refreshPermissionHealth() {
        perform("Refreshing permission health...") {
            self.permissionHealth = try await self.refreshAllHealth()
            self.refresh()
        }
    }

    func openSetup() {
        selectedTab = .settings
    }

    func openSettings() {
        selectedTab = .settings
    }

    func toggleSettings() {
        selectedTab = selectedTab == .settings ? .queue : .settings
    }

    func openQueueWindow() {
        selectedTab = .queue
        showQueueWindow?()
    }

    func quitNudge() {
        NSApp.terminate(nil)
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    func openGeminiDiagnostics() {
        refreshGeminiDiagnostics()
        isShowingGeminiDiagnostics = true
    }

    func refreshGeminiDiagnostics() {
        do {
            geminiDiagnostics = try store.fetchGeminiDiagnosticRuns(limit: 20)
        } catch {
            statusMessage = "Gemini diagnostics refresh failed: \(error.localizedDescription)"
        }
    }

    func runAppleMessagesTextDiagnostic() {
        perform("Checking Messages text storage...") {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
            let diagnostics = try self.messagesImporter.textDiagnostics(since: cutoff)
            self.appleMessagesTextDiagnostics = diagnostics
            self.statusMessage = "Messages text check: \(diagnostics.recoveredOutgoingWithoutPlainTextCount) sent rows can be recovered; \(diagnostics.outgoingUnresolvedAfterDecode) sent rows still need another decoder."
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
            self.statusMessage = "Messages decode trace: \(report.threadMatches.count) chat matches, \(report.outgoingRowCount) sent rows, \(report.placeholderRowCount) placeholders."
        }
    }

    func replayLatestGeminiRun() {
        perform("Replaying latest Gemini candidate set...") {
            let latest = try self.latestGeminiDiagnosticRun()
            let replay = try await self.replayGeminiRun(latest)
            self.statusMessage = "Replay \(replay.outcome.rawValue): \(replay.detail)"
            self.refreshGeminiDiagnostics()
        }
    }

    func copyLatestGeminiDiagnostics() {
        do {
            let latest = try latestGeminiDiagnosticRun()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(redactedDiagnosticsText(for: latest), forType: .string)
            statusMessage = "Copied redacted Gemini diagnostics."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearGeminiDiagnostics() {
        perform("Clearing Gemini diagnostics...") {
            try self.store.clearGeminiDiagnosticRuns()
            self.geminiDiagnostics = []
            self.appleMessagesTextDiagnostics = nil
            self.appleMessagesDecodeTraceReport = nil
            self.statusMessage = "Cleared diagnostics. Messages, suggestions, profile, and permissions were left untouched."
        }
    }
#endif

    func buildMockInbox() {
        perform("Building mock inbox...") {
            let importResult = try self.importer.importSampleConversations(into: self.store)
            let (generated, mode, fallbackError) = try await self.generateStoredSuggestions()
            let importSummary = importResult.insertedMessages > 0
                ? "Imported \(importResult.insertedMessages) sample messages"
                : "Sample messages already imported"
            let aiSummary = self.generationSummary(generated, mode: mode)
            if let fallbackError {
                self.statusMessage = "\(importSummary). \(aiSummary) after cloud fallback: \(fallbackError.localizedDescription)"
            } else {
                self.statusMessage = "\(importSummary). \(aiSummary)."
            }
            self.refresh()
        }
    }

    func importSampleConversations() {
        perform("Importing sample conversations...") {
            let result = try self.importer.importSampleConversations(into: self.store)
            self.statusMessage = "Imported \(result.insertedMessages) messages; skipped \(result.skippedMessages) duplicates."
            self.refresh()
        }
    }

    func importAppleMessagesRecent() {
        syncAndGenerateSuggestions(reason: .manual)
    }

    func generateSuggestions() {
        syncAndGenerateSuggestions(reason: .manual)
    }

    func syncAndGenerateSuggestions(reason: NudgeSuggestionSyncReason) {
        if (try? store.managedState().mode) == .managed { refreshManaged(reason: reason); return }
        guard !isGeneratingSuggestions else {
            if reason == .manual {
                statusMessage = "Nudge is already checking Messages."
            }
            return
        }

        isGeneratingSuggestions = true
        statusMessage = reason.inProgressMessage
        Task { @MainActor in
            defer {
                self.isGeneratingSuggestions = false
            }
            do {
                let activeAlertsBeforeSync = try self.activeAlertIdentitiesFromStore()
                let importResult = try await self.importRecentMessages()
                let (generated, mode, fallbackError) = try await self.generateStoredSuggestions()
                let activeAlertsAfterSync = try self.activeGeneratedAlertsFromStore()
                self.lastRefreshFailed = false
                self.lastSyncAt = Date()
                self.statusMessage = "Checked Messages: \(importResult.insertedMessages) new, \(importResult.skippedMessages) unchanged. \(self.generationSummary(generated, mode: mode))."
                if generated.rankedDraftCount == 0 {
                    self.statusMessage += " Nothing needs attention right now."
                } else if generated.activeSavedCount == 0 {
                    self.statusMessage += " Everything found is already completed or dismissed."
                }
                if let fallbackError {
                    self.statusMessage += " Cloud AI fell back locally: \(fallbackError.localizedDescription)"
                }
                self.refresh()
                await self.notifyForNewPeriodicAlerts(
                    reason: reason,
                    previousIdentities: activeAlertsBeforeSync,
                    activeAlertsAfterSync: activeAlertsAfterSync
                )
            } catch {
                self.lastRefreshFailed = true
                self.statusMessage = "Refresh failed: \(error.localizedDescription)"
                self.refresh()
            }
        }
    }

    func regenerateSuggestions() {
        perform("Regenerating suggestions...") {
            try self.store.deleteSuggestions()
            let (generated, mode, fallbackError) = try await self.generateStoredSuggestions()
            self.statusMessage = "Cleared old suggestions. \(self.generationSummary(generated, mode: mode))."
            if generated.rankedDraftCount == 0 {
                self.statusMessage += " No recent Messages threads matched the lenient Messages rules."
            }
            if let fallbackError {
                self.statusMessage += " Cloud AI fell back locally: \(fallbackError.localizedDescription)"
            }
            self.refresh()
        }
    }

    func reimportSourcesAndRegenerate() {
        perform("Reimporting Messages...") {
            var summaries: [String] = []
            do {
                let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
                let result = try await self.messagesImporter.importRecent(into: self.store, since: cutoff)
                summaries.append("Messages +\(result.insertedMessages)/\(result.skippedMessages) skipped")
            } catch {
                summaries.append("Messages failed: \(error.localizedDescription)")
            }

            try self.store.deleteSuggestions()
            let (generated, mode, fallbackError) = try await self.generateStoredSuggestions()
            self.statusMessage = "\(summaries.joined(separator: ". ")). \(self.generationSummary(generated, mode: mode))."
            if let fallbackError {
                self.statusMessage += " Cloud AI fell back locally: \(fallbackError.localizedDescription)"
            }
            self.refresh()
        }
    }

    func clearSuggestions() {
        perform("Clearing suggestions...") {
            try self.store.deleteSuggestions()
            self.statusMessage = "Cleared generated suggestions. Click Refresh to create new alerts."
            self.refresh()
        }
    }

    func clearImportedCache() {
        perform("Clearing imported cache...") {
            try self.store.deleteImportedConversationCache()
            self.statusMessage = "Cleared imported Messages and suggestions. Reimport Messages to continue."
            self.refresh()
        }
    }

    func complete(_ suggestion: Suggestion) {
        if managedState.recommendations[suggestion.id] != nil { managedAction(.done, id: suggestion.id); return }
        update(suggestion, to: .completed)
    }

    func complete(_ manualItem: ManualQueueItem) {
        perform("Completing item...") {
            try self.store.updateManualQueueItemState(id: manualItem.id, state: .completed)
            self.statusMessage = "Completed \(manualItem.title)."
            self.refresh()
        }
    }

    func undoCompleted(_ suggestion: Suggestion) {
        if managedState.recommendations[suggestion.id] != nil { managedAction(.undone, id: suggestion.id); return }
        perform("Restoring suggestion...") {
            try self.store.updateSuggestionState(id: suggestion.id, state: .new)
            self.statusMessage = "Restored \(suggestion.evidence.threadTitle) to the inbox."
            self.refresh()
        }
    }

    func undoCompleted(_ item: NudgeCompletedQueueItem) {
        switch item {
        case .suggestion(let suggestion):
            undoCompleted(suggestion)
        case .manual(let manualItem):
            undoCompleted(manualItem)
        }
    }

    func undoCompleted(_ manualItem: ManualQueueItem) {
        perform("Restoring item...") {
            try self.store.updateManualQueueItemState(id: manualItem.id, state: .active)
            self.statusMessage = "Restored \(manualItem.title) to the queue."
            self.refresh()
        }
    }

    func goToFirstQueuePage() {
        setQueuePage(0)
    }

    func goToPreviousQueuePage() {
        setQueuePage(queuePageIndex - 1)
    }

    func goToNextQueuePage() {
        setQueuePage(queuePageIndex + 1)
    }

    func goToLastQueuePage() {
        setQueuePage(maxQueuePageIndex(forItemCount: activeQueueCount))
    }

    func update(_ suggestion: Suggestion, to state: SuggestionState) {
        perform("Updating suggestion...") {
            try self.store.updateSuggestionState(id: suggestion.id, state: state)
            self.statusMessage = "Marked \(state.displayName.lowercased())."
            self.refresh()
        }
    }

    func snooze(_ suggestion: Suggestion) {
        perform("Snoozing suggestion...") {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)
            try self.store.updateSuggestionState(id: suggestion.id, state: .snoozed, snoozedUntil: tomorrow)
            self.statusMessage = "Snoozed until tomorrow."
            self.refresh()
        }
    }

    func eraseAllData() {
        perform("Deleting local dev data...") {
            try self.store.eraseAllData()
            self.statusMessage = "Deleted local NudgeDev data."
            self.refresh()
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

    private func refreshAllHealth() async throws -> [PermissionHealth] {
        let health = try await permissionCoordinator.refresh()
        return health.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func importRecentMessages() async throws -> ImportResult {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
        return try await messagesImporter.importRecent(into: store, since: cutoff)
    }

    private func refreshQueuePresentation(preserving itemID: String? = nil) throws {
        let currentActiveSuggestions = activeSuggestions
        activeAlertCount = currentActiveSuggestions.count
        alertLegendItems = makeAlertLegendItems(from: currentActiveSuggestions)
        let cards = try makeSuggestionCards(from: currentActiveSuggestions)
        suggestionCards = cards
        let allQueueItems = makeQueueItems(from: cards)
        if let itemID, let index = allQueueItems.firstIndex(where: { $0.id == itemID }) { queuePageIndex = index / Self.queuePageSize }
        queuePageIndex = min(queuePageIndex, maxQueuePageIndex(forItemCount: allQueueItems.count))
        queueItems = pageItems(from: allQueueItems)
    }

    func messagesURL(for suggestion: Suggestion) -> URL? {
        if let record = managedState.threads[suggestion.threadId] { return AppleMessagesLink.url(threadExternalId: record.externalId) }
        guard sources.contains(where: { $0.id == suggestion.sourceId && $0.kind == .appleMessages }),
              let thread = threads.first(where: { $0.id == suggestion.threadId && $0.sourceId == suggestion.sourceId })
        else {
            return nil
        }
        return AppleMessagesLink.url(threadExternalId: thread.externalId)
    }

    private func makeSuggestionCards(from suggestions: [Suggestion]) throws -> [NudgeSuggestionCard] {
        try suggestions.map { suggestion in
            if let rec = managedState.recommendations[suggestion.id], let record = managedState.threads[rec.threadId] {
                let preview = record.snapshot.messages.map { message in
                    Message(id: message.id, sourceId: "apple-messages-local", threadId: rec.threadId, externalId: message.id,
                        senderLabel: record.localSenderLabels[message.senderId] ?? record.snapshot.participants.first(where: { $0.id == message.senderId })?.displayName ?? "Unknown", sentAt: message.sentAt,
                        body: message.contentAvailability == .available ? message.body : (message.contentAvailability == .attachmentOnly ? "[Attachment; content unavailable]" : "[Message content unavailable]"), isFromUser: message.isFromUser)
                }
                return NudgeSuggestionCard(suggestion: suggestion, recentMessages: preview, messagePlatform: NudgeMessagePlatform(threadExternalId: record.externalId), messagesURL: messagesURL(for: suggestion), managedRecommendation: rec)
            }
            let thread = threads.first { $0.id == suggestion.threadId }
            return NudgeSuggestionCard(
                suggestion: suggestion,
                recentMessages: try store.fetchRecentMessages(threadId: suggestion.threadId, limit: Self.suggestionPreviewMessageLimit),
                messagePlatform: NudgeMessagePlatform(threadExternalId: thread?.externalId),
                messagesURL: messagesURL(for: suggestion)
            )
        }
    }

    private func makeQueueItems(from suggestionCards: [NudgeSuggestionCard]) -> [NudgeQueueItem] {
        let suggestionItems = suggestionCards.map(NudgeQueueItem.suggestion)
        let manualItems = activeManualItems.map(NudgeQueueItem.manual)
        if managedState.mode == .managed { return activeManualItems.sorted { $0.createdAt > $1.createdAt }.map(NudgeQueueItem.manual) + suggestionItems }
        return (suggestionItems + manualItems).sorted(by: isHigherPriorityQueueItem)
    }

    private func setQueuePage(_ index: Int) {
        queuePageIndex = max(0, min(index, maxQueuePageIndex(forItemCount: activeQueueCount)))
        do {
            try refreshQueuePresentation()
        } catch {
            statusMessage = "Could not change queue page: \(error.localizedDescription)"
        }
    }

    private func pageItems(from items: [NudgeQueueItem]) -> [NudgeQueueItem] {
        guard !items.isEmpty else { return [] }
        let start = queuePageIndex * Self.queuePageSize
        guard start < items.count else { return [] }
        let end = min(items.count, start + Self.queuePageSize)
        return Array(items[start..<end])
    }

    private func maxQueuePageIndex(forItemCount count: Int) -> Int {
        count > 0 ? (count - 1) / Self.queuePageSize : 0
    }

    private func makeAlertLegendItems(from suggestions: [Suggestion]) -> [NudgeAlertLegendItem] {
        let countsByType = Dictionary(grouping: suggestions, by: \.type)
            .mapValues(\.count)
        return SuggestionType.allCases.map { type in
            NudgeAlertLegendItem(type: type, count: countsByType[type, default: 0])
        }
    }

    private func activeAlertIdentitiesFromStore() throws -> Set<NudgeAlertIdentity> {
        Set(try activeGeneratedAlertsFromStore().map(NudgeAlertIdentity.init))
    }

    private func activeGeneratedAlertsFromStore() throws -> [Suggestion] {
        let storedSources = try store.fetchSources()
        let sourceById = Dictionary(uniqueKeysWithValues: storedSources.map { ($0.id, $0) })
        return try store.fetchSuggestions(includeCompleted: false)
            .filter { suggestion in
                if let source = sourceById[suggestion.sourceId] {
                    return Self.prototypeSourceKinds.contains(source.kind)
                }
                return suggestion.evidence.sourceApp.localizedCaseInsensitiveContains("messages")
            }
            .sorted(by: isHigherPriorityAlert)
    }

    private func notifyForNewPeriodicAlerts(
        reason: NudgeSuggestionSyncReason,
        previousIdentities: Set<NudgeAlertIdentity>,
        activeAlertsAfterSync: [Suggestion]
    ) async {
        guard reason == .periodic else { return }
        guard profile?.notificationCadence != .quiet else { return }
        guard !isQueueInterfaceVisible() else { return }

        let newAlerts = activeAlertsAfterSync.filter { suggestion in
            !previousIdentities.contains(NudgeAlertIdentity(suggestion))
        }
        guard !newAlerts.isEmpty else { return }

        await alertNotifier.notifyNewAlerts(newAlerts)
    }

    func managedAction(_ action: RecommendationFeedback.Action, id: String, days: Int = 1) {
        do {
            try store.managedAction(action, recommendationId: id, days: days, timeZone: TimeZone(identifier: profile?.timeZoneIdentifier ?? "") ?? .current)
            lastManagedActionId = action == .undone ? nil : id
            statusMessage = action == .done ? "Done." : "Conversation preference saved."
            refresh()
        } catch { statusMessage = error.localizedDescription }
    }

    private func managedDisplaySuggestion(_ rec: ThreadRecommendation) -> Suggestion {
        let record = managedState.threads[rec.threadId]
        let state: SuggestionState
        switch rec.state { case .active: state = .new; case .done: state = .completed; case .dismissed, .muted: state = .dismissed; case .snoozed: state = .snoozed; case .superseded: state = .superseded }
        return Suggestion(id: rec.id, type: .followUpNudge, state: state, title: rec.content.headline,
            action: SuggestionAction(text: rec.content.nextStep), sourceId: "apple-messages-local", threadId: rec.threadId, confidence: 1,
            evidence: Evidence(sourceApp: "Apple Messages", threadTitle: record?.localDisplayTitle ?? record?.snapshot.title ?? "Conversation", messageId: rec.evidenceMessages.first?.id ?? rec.id,
                snippet: rec.evidenceText().joined(separator: "\n\n"), sourceTimestamp: record?.snapshot.coverage.excerptEnd ?? rec.assessedAt),
            createdAt: rec.createdAt, updatedAt: rec.assessedAt, snoozedUntil: rec.snoozedUntil, completedAt: rec.actionAt)
    }

    private func refreshManaged(reason: NudgeSuggestionSyncReason) {
        guard !isGeneratingSuggestions else { managedRefreshRequested = true; return }
        isGeneratingSuggestions = true
        lastRefreshFailed = false
        statusMessage = "Checking managed AI access…"
        Task { @MainActor in
            defer {
                self.isGeneratingSuggestions = false
                if self.managedRefreshRequested {
                    self.managedRefreshRequested = false
                    Task { @MainActor in self.syncAndGenerateSuggestions(reason: .manual) }
                }
            }
            do {
                guard let configuration = ManagedServiceConfiguration.configured() else { throw ManagedAIError.unavailable("This build has no managed service configured. Add the development or alpha project configuration before signing in.") }
                let state = try self.store.managedState()
                let client = ManagedAIClient(configuration: configuration, consentVersion: state.consentVersion)
                let coordinator = ManagedAssessmentCoordinator(store: self.store, service: client, collector: ManagedMessagesCollector(contactResolver: MacContactResolver()))
                try await coordinator.refresh(profile: self.profile ?? UserProfile(displayName: NSFullUserName()), bypassFailureBackoff: reason == .manual) {
                    self.statusMessage = $0
                    if let state = try? self.store.managedState() { self.managedState = state }
                }
                self.refresh()
                self.lastRefreshFailed = self.managedState.coverage.failed > 0
                self.statusMessage = self.managedState.coverage.detail
            } catch {
                self.lastRefreshFailed = true
                try? self.store.updateManagedState { state in
                    state.coverage.detail = error.localizedDescription
                    state.coverage.failed = max(1,state.coverage.failed)
                    for id in state.recommendations.keys { state.recommendations[id]?.stale = true }
                }
                self.refresh(); self.statusMessage = error.localizedDescription
            }
        }
    }

    private func generateStoredSuggestions() async throws -> (generated: SuggestionGenerationReport, mode: String, fallbackError: Error?) {
        let config = GeminiConfig.fromEnvironment()
        let inputs = try storedRankingInputs()

        guard (try store.managedState()).mode != .local, profile?.cloudAIEnabled == true else {
            let report = try await localFallbackReport()
#if NUDGE_INTERNAL_DIAGNOSTICS
            saveGeminiDiagnosticRun(
                model: config?.model ?? "Gemini",
                start: Date(),
                outcome: .skipped,
                category: .disabled,
                fallbackUsed: false,
                httpStatus: nil,
                candidates: inputs.candidates,
                decisionCount: 0,
                rankedCount: report.rankedDraftCount,
                savedCount: report.savedCount,
                detail: "Cloud AI is disabled; local ranking generated suggestions."
            )
#endif
            return (report, SuggestionGenerationMode.localFallback.displayName, nil)
        }

        guard let config else {
            let report = try await localFallbackReport()
#if NUDGE_INTERNAL_DIAGNOSTICS
            saveGeminiDiagnosticRun(
                model: "Gemini",
                start: Date(),
                outcome: .skipped,
                category: .missingConfig,
                fallbackUsed: true,
                httpStatus: nil,
                candidates: inputs.candidates,
                decisionCount: 0,
                rankedCount: report.rankedDraftCount,
                savedCount: report.savedCount,
                detail: "Cloud AI is enabled but Gemini credentials are missing; local fallback generated suggestions."
            )
#endif
            return (report, SuggestionGenerationMode.localFallback.displayName, GeminiDebugError.missingGeminiConfig)
        }

        let start = Date()
        guard !inputs.candidates.isEmpty else {
            let saved = try store.replaceActiveSuggestions(with: [])
            let report = SuggestionGenerationReport(
                messageCount: inputs.context.messages.count,
                rawDraftCount: 0,
                decisionCount: 0,
                rankedDraftCount: 0,
                savedSuggestions: saved
            )
#if NUDGE_INTERNAL_DIAGNOSTICS
            saveGeminiDiagnosticRun(
                model: config.model,
                start: start,
                outcome: .skipped,
                category: .noCandidates,
                fallbackUsed: false,
                httpStatus: nil,
                candidates: [],
                decisionCount: 0,
                rankedCount: 0,
                savedCount: report.savedCount,
                detail: "Local gates found no plausible candidate threads, so Gemini was not called."
            )
#endif
            return (report, SuggestionGenerationMode.cloudAI.displayName, nil)
        }

        do {
            let service = GeminiConversationRankingService(config: config)
            let response = try await service.rankCandidatesWithMetadata(inputs.candidates, context: inputs.context)
            let rankedDrafts = inputs.policy.rankedDrafts(response.decisions, candidates: inputs.candidates, context: inputs.context)
            let saved = try store.replaceActiveSuggestions(with: rankedDrafts)
            let report = SuggestionGenerationReport(
                messageCount: inputs.context.messages.count,
                rawDraftCount: inputs.candidates.count,
                decisionCount: response.decisions.count,
                rankedDraftCount: rankedDrafts.count,
                savedSuggestions: saved
            )
#if NUDGE_INTERNAL_DIAGNOSTICS
            saveGeminiDiagnosticRun(
                model: config.model,
                start: start,
                outcome: .success,
                category: .success,
                fallbackUsed: false,
                httpStatus: response.httpStatus,
                candidates: inputs.candidates,
                decisionCount: response.decisions.count,
                rankedCount: rankedDrafts.count,
                savedCount: report.savedCount,
                detail: "Gemini ranked candidate threads successfully."
            )
#endif
            return (report, SuggestionGenerationMode.cloudAI.displayName, nil)
        } catch {
            let geminiDuration = max(0, Int(Date().timeIntervalSince(start) * 1000))
            let report = try await localFallbackReport()
#if NUDGE_INTERNAL_DIAGNOSTICS
            saveGeminiDiagnosticRun(
                model: config.model,
                start: start,
                durationMilliseconds: geminiDuration,
                outcome: .failure,
                category: diagnosticCategory(for: error),
                fallbackUsed: true,
                httpStatus: diagnosticHTTPStatus(for: error),
                candidates: inputs.candidates,
                decisionCount: 0,
                rankedCount: report.rankedDraftCount,
                savedCount: report.savedCount,
                detail: redactedDiagnosticDetail(for: error)
            )
#endif
            return (report, SuggestionGenerationMode.localFallback.displayName, error)
        }
    }

    private func localFallbackReport() async throws -> SuggestionGenerationReport {
        let engine = SuggestionEngine(
            store: store,
            rankingService: LocalConversationRankingService(),
            enabledSourceKinds: Self.prototypeSourceKinds
        )
        return try await engine.generateReportFromStoredMessages()
    }

    private func storedRankingInputs() throws -> StoredRankingInputs {
        let context = SuggestionContext(
            sources: try store.fetchSources(),
            threads: try store.fetchThreads(),
            messages: try store.fetchMessages(limit: 500),
            userProfile: try store.fetchUserProfile()
        )
        let policy = ConversationRecommendationPolicy()
        let candidates = ConversationCandidateBuilder(
            policy: policy,
            enabledSourceKinds: Self.prototypeSourceKinds
        ).candidates(from: context)
        return StoredRankingInputs(context: context, policy: policy, candidates: candidates)
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    private func latestGeminiDiagnosticRun() throws -> GeminiDiagnosticRun {
        if let latest = geminiDiagnostics.first {
            return latest
        }
        guard let latest = try store.fetchGeminiDiagnosticRuns(limit: 1).first else {
            throw GeminiDebugError.noDiagnostics
        }
        return latest
    }

    private func replayGeminiRun(_ run: GeminiDiagnosticRun) async throws -> GeminiDiagnosticRun {
        let config = GeminiConfig.fromEnvironment()
        let inputs = try storedRankingInputs()
        let existingMessageIds = Set(inputs.context.messages.map(\.id))
        let missingMessageIds = Set(run.candidateMessageIds).subtracting(existingMessageIds)
        let start = Date()
        let model = config?.model ?? run.model

        guard let config else {
            return saveAndReturnGeminiDiagnosticRun(
                model: model,
                start: start,
                outcome: .skipped,
                category: .missingConfig,
                fallbackUsed: false,
                httpStatus: nil,
                candidates: [],
                decisionCount: 0,
                rankedCount: 0,
                savedCount: 0,
                detail: "Replay skipped because Gemini credentials are missing."
            )
        }

        guard missingMessageIds.isEmpty else {
            return saveAndReturnGeminiDiagnosticRun(
                model: model,
                start: start,
                outcome: .failure,
                category: .invalidEvidence,
                fallbackUsed: false,
                httpStatus: nil,
                candidates: [],
                decisionCount: 0,
                rankedCount: 0,
                savedCount: 0,
                detail: "Replay unavailable; \(missingMessageIds.count) referenced message IDs no longer exist in the local cache."
            )
        }

        let targetThreadIds = Set(run.candidateThreadIds)
        let replayCandidates = inputs.candidates.filter { targetThreadIds.contains($0.threadId) }
        guard !replayCandidates.isEmpty else {
            return saveAndReturnGeminiDiagnosticRun(
                model: model,
                start: start,
                outcome: .skipped,
                category: .noCandidates,
                fallbackUsed: false,
                httpStatus: nil,
                candidates: [],
                decisionCount: 0,
                rankedCount: 0,
                savedCount: 0,
                detail: run.candidateThreadIds.isEmpty
                    ? "Replay skipped because the latest diagnostic run had no candidate thread IDs."
                    : "Referenced messages exist, but no replayable candidates currently pass local gates."
            )
        }

        do {
            let service = GeminiConversationRankingService(config: config)
            let response = try await service.rankCandidatesWithMetadata(replayCandidates, context: inputs.context)
            let ranked = inputs.policy.rankedDrafts(response.decisions, candidates: replayCandidates, context: inputs.context)
            return saveAndReturnGeminiDiagnosticRun(
                model: config.model,
                start: start,
                outcome: .success,
                category: .success,
                fallbackUsed: false,
                httpStatus: response.httpStatus,
                candidates: replayCandidates,
                decisionCount: response.decisions.count,
                rankedCount: ranked.count,
                savedCount: 0,
                detail: "Replay completed; suggestions were not saved."
            )
        } catch {
            return saveAndReturnGeminiDiagnosticRun(
                model: config.model,
                start: start,
                outcome: .failure,
                category: diagnosticCategory(for: error),
                fallbackUsed: false,
                httpStatus: diagnosticHTTPStatus(for: error),
                candidates: replayCandidates,
                decisionCount: 0,
                rankedCount: 0,
                savedCount: 0,
                detail: redactedDiagnosticDetail(for: error)
            )
        }
    }

    @discardableResult
    private func saveAndReturnGeminiDiagnosticRun(
        model: String,
        start: Date,
        durationMilliseconds: Int? = nil,
        outcome: GeminiDiagnosticOutcome,
        category: GeminiDiagnosticErrorCategory,
        fallbackUsed: Bool,
        httpStatus: Int?,
        candidates: [ConversationRankingCandidate],
        decisionCount: Int,
        rankedCount: Int,
        savedCount: Int,
        detail: String
    ) -> GeminiDiagnosticRun {
        let run = makeGeminiDiagnosticRun(
            model: model,
            start: start,
            durationMilliseconds: durationMilliseconds,
            outcome: outcome,
            category: category,
            fallbackUsed: fallbackUsed,
            httpStatus: httpStatus,
            candidates: candidates,
            decisionCount: decisionCount,
            rankedCount: rankedCount,
            savedCount: savedCount,
            detail: detail
        )
        do {
            try store.saveGeminiDiagnosticRun(run)
            geminiDiagnostics = try store.fetchGeminiDiagnosticRuns(limit: 20)
        } catch {
            statusMessage = "Gemini diagnostics save failed: \(error.localizedDescription)"
        }
        return run
    }

    private func saveGeminiDiagnosticRun(
        model: String,
        start: Date,
        durationMilliseconds: Int? = nil,
        outcome: GeminiDiagnosticOutcome,
        category: GeminiDiagnosticErrorCategory,
        fallbackUsed: Bool,
        httpStatus: Int?,
        candidates: [ConversationRankingCandidate],
        decisionCount: Int,
        rankedCount: Int,
        savedCount: Int,
        detail: String
    ) {
        _ = saveAndReturnGeminiDiagnosticRun(
            model: model,
            start: start,
            durationMilliseconds: durationMilliseconds,
            outcome: outcome,
            category: category,
            fallbackUsed: fallbackUsed,
            httpStatus: httpStatus,
            candidates: candidates,
            decisionCount: decisionCount,
            rankedCount: rankedCount,
            savedCount: savedCount,
            detail: detail
        )
    }

    private func makeGeminiDiagnosticRun(
        model: String,
        start: Date,
        durationMilliseconds: Int?,
        outcome: GeminiDiagnosticOutcome,
        category: GeminiDiagnosticErrorCategory,
        fallbackUsed: Bool,
        httpStatus: Int?,
        candidates: [ConversationRankingCandidate],
        decisionCount: Int,
        rankedCount: Int,
        savedCount: Int,
        detail: String
    ) -> GeminiDiagnosticRun {
        let messageIds = Set(candidates.flatMap { candidate in
            candidate.recentMessages.map(\.id) + [candidate.latestMessage.id]
        })
        return GeminiDiagnosticRun(
            model: model,
            durationMilliseconds: durationMilliseconds ?? max(0, Int(Date().timeIntervalSince(start) * 1000)),
            outcome: outcome,
            errorCategory: category,
            fallbackUsed: fallbackUsed,
            httpStatus: httpStatus,
            candidateCount: candidates.count,
            decisionCount: decisionCount,
            rankedCount: rankedCount,
            savedCount: savedCount,
            candidateThreadIds: candidates.map(\.threadId),
            candidateMessageIds: Array(messageIds).sorted(),
            detail: redacted(detail)
        )
    }

    private func diagnosticCategory(for error: Error) -> GeminiDiagnosticErrorCategory {
        if let geminiError = error as? GeminiError {
            switch geminiError {
            case .requestFailed:
                return .http
            case .missingOutputText:
                return .missingOutput
            case .invalidJSON:
                return .invalidJSON
            case .invalidEvidenceReference:
                return .invalidEvidence
            }
        }
        if error is URLError {
            return .network
        }
        return .network
    }

    private func diagnosticHTTPStatus(for error: Error) -> Int? {
        (error as? GeminiError)?.httpStatus
    }

    private func redactedDiagnosticDetail(for error: Error) -> String {
        if let geminiError = error as? GeminiError {
            switch geminiError {
            case .requestFailed(let statusCode, _):
                if statusCode == 429 {
                    return "Gemini rate limit or quota was exceeded. Wait before generating again, or use a Gemini key/model with more available quota. Local fallback generated suggestions."
                }
                return statusCode.map { "Gemini returned HTTP \($0). Check the API key, model name, and request schema." }
                    ?? "Gemini request failed before an HTTP status was available."
            case .missingOutputText:
                return "Gemini responded without a text output field."
            case .invalidJSON(let detail, _):
                return "Gemini output could not be decoded as JSON: \(detail)"
            case .invalidEvidenceReference(let id, _):
                return "Gemini referenced a thread or message ID that was not in the candidate set: \(id)"
            }
        }
        if let urlError = error as? URLError {
            return "Network error: \(urlError.localizedDescription)"
        }
        return "Gemini failed: \(error.localizedDescription)"
    }

    private func redacted(_ detail: String) -> String {
        let flattened = detail
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(flattened.prefix(320))
    }

    private func redactedDiagnosticsText(for run: GeminiDiagnosticRun) -> String {
        """
        Gemini Diagnostics
        id: \(run.id)
        createdAt: \(ISO8601DateFormatter().string(from: run.createdAt))
        model: \(run.model)
        outcome: \(run.outcome.rawValue)
        errorCategory: \(run.errorCategory.rawValue)
        httpStatus: \(run.httpStatus.map(String.init) ?? "none")
        durationMs: \(run.durationMilliseconds)
        fallbackUsed: \(run.fallbackUsed)
        candidateCount: \(run.candidateCount)
        decisionCount: \(run.decisionCount)
        rankedCount: \(run.rankedCount)
        savedCount: \(run.savedCount)
        candidateThreadIds: \(run.candidateThreadIds.joined(separator: ", "))
        candidateMessageIds: \(run.candidateMessageIds.joined(separator: ", "))
        detail: \(run.detail)
        """
    }
#endif

    private func generationSummary(_ report: SuggestionGenerationReport, mode: String) -> String {
        "\(mode) read \(report.messageCount) messages, drafted \(report.rawDraftCount), judged \(report.decisionCount), ranked \(report.rankedDraftCount), saved \(report.savedCount) (\(report.activeSavedCount) active)"
    }

    private func isHigherPriorityAlert(_ lhs: Suggestion, than rhs: Suggestion) -> Bool {
        let leftPriority = priorityRank(for: lhs)
        let rightPriority = priorityRank(for: rhs)
        if leftPriority != rightPriority {
            return leftPriority > rightPriority
        }

        let leftUrgent = lhs.type == .deadline || lhs.type == .calendarEvent || lhs.action.dueDate != nil
        let rightUrgent = rhs.type == .deadline || rhs.type == .calendarEvent || rhs.action.dueDate != nil
        if leftUrgent != rightUrgent {
            return leftUrgent
        }

        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return lhs.evidence.sourceTimestamp > rhs.evidence.sourceTimestamp
    }

    private func isHigherPriorityQueueItem(_ lhs: NudgeQueueItem, than rhs: NudgeQueueItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        switch (lhs, rhs) {
        case (.suggestion(let left), .suggestion(let right)):
            return isHigherPriorityAlert(left.suggestion, than: right.suggestion)
        case (.suggestion, .manual):
            return false
        case (.manual, .suggestion):
            return true
        case (.manual(let left), .manual(let right)):
            return left.id < right.id
        }
    }

    private func priorityRank(for suggestion: Suggestion) -> Int {
        if suggestion.confidence >= 0.85 { return 3 }
        if suggestion.confidence >= 0.65 { return 2 }
        if suggestion.confidence >= 0.15 { return 1 }
        return 0
    }

    private func isPrototypeSuggestion(_ suggestion: Suggestion) -> Bool {
        guard let source = sources.first(where: { $0.id == suggestion.sourceId }) else {
            return suggestion.evidence.sourceApp.localizedCaseInsensitiveContains("messages")
        }
        return Self.prototypeSourceKinds.contains(source.kind)
    }
}

private struct StoredRankingInputs {
    var context: SuggestionContext
    var policy: ConversationRecommendationPolicy
    var candidates: [ConversationRankingCandidate]
}

private enum GeminiDebugError: Error, LocalizedError {
#if NUDGE_INTERNAL_DIAGNOSTICS
    case noDiagnostics
#endif
    case missingGeminiConfig

    var errorDescription: String? {
        switch self {
#if NUDGE_INTERNAL_DIAGNOSTICS
        case .noDiagnostics:
            return "No Gemini diagnostics are available yet. Click Refresh with Gemini enabled first."
#endif
        case .missingGeminiConfig:
            return "Gemini credentials are missing."
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
