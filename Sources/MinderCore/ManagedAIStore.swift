import Foundation

public struct ThreadRecommendation: Codable, Equatable, Identifiable {
    public enum State: String, Codable { case active, done, dismissed, snoozed, muted, superseded }
    public var id: String; public var threadId: String; public var content: RecommendationContent
    public var state: State; public var createdAt: Date; public var assessedAt: Date; public var actionAt: Date?
    public var snoozedUntil: Date?; public var substantiveRevision: String; public var goalRevision: Int
    public var evidenceMessages: [ContextMessage]; public var evidenceFacts: [ActivityFact]
    public var stale: Bool; public var notifiedAt: Date?
    public var lastRank: Int? = nil
    public func evidenceText() -> [String] {
        content.evidenceRefs.compactMap { ref in
            ref.kind == .message ? evidenceMessages.first(where: { $0.id == ref.id }).map { "\($0.sentAt.formatted(date: .abbreviated, time: .shortened)): \($0.body)" } : evidenceFacts.first(where: { $0.id == ref.id })?.summary
        }
    }
}
public struct ManagedThreadRecord: Codable {
    public var snapshot: ThreadSnapshot
    public var localThreadId: String
    public var externalId: String // Mac only: never serialized as part of API requests.
    public var localDisplayTitle: String?
    public var localSenderLabels: [String: String] = [:]
    public var dailyActivity: [DailyActivity] = []
    public var feedback: [RecommendationFeedback] = []
    public var feedbackRevision = 0
    public var muted = false
    public var seenScanId: String?
    public var sourcePresent = true
    public var assessment: ThreadAssessment?
    public var assessedAt: Date?
    public var lastAttemptAt: Date?
    public var cacheKey: String?
    public var unresolved: String?
    public var lastAttemptFailed = false
    public var stagedRecommendation: ThreadRecommendation?
    public var pendingNoAction = false
}
public struct AnalysisCoverage: Codable {
    public var total = 0; public var reviewed = 0; public var unresolved = 0; public var failed = 0
    public var scanComplete = false; public var lastSuccessAt: Date?; public var detail = "Refresh to analyze Messages."
    public var isComplete: Bool { scanComplete && unresolved == 0 && failed == 0 && reviewed == total }
}
public struct ManagedLocalState: Codable {
    public enum Mode: String, Codable { case local, managed }
    public var mode: Mode = .local
    public var goal = UserGoal()
    public var accountId: String?
    public var cacheAccountId: String?
    public var consentVersion = 0
    public var revision = 0
    public var threads: [String: ManagedThreadRecord] = [:]
    public var recommendations: [String: ThreadRecommendation] = [:]
    public var orderedIds: [String] = []
    public var legacyMigrationComplete = false
    public var rankingPassCache: [String: [String]] = [:]
    public var coverage = AnalysisCoverage()
    public var scanCursor: Int = 0
    public var scanStartedAt: Date?
    public var scanId: String?
    public var lastNotificationAt: Date?
    public var status: ManagedAIStatus?
    public init() {}
    public func visible(at now: Date = Date()) -> [ThreadRecommendation] {
        orderedIds.compactMap { recommendations[$0] }.filter { rec in
            !(threads[rec.threadId]?.muted ?? false) && (rec.state == .active || (rec.state == .snoozed && (rec.snoozedUntil ?? .distantFuture) <= now))
        }
    }
}
extension MinderStore {
    func migrateManagedAI() throws {
        try database.execute("CREATE TABLE IF NOT EXISTS managed_ai_state (id INTEGER PRIMARY KEY CHECK(id = 1), json TEXT NOT NULL)")
    }
    public func managedState() throws -> ManagedLocalState {
        guard let row = try database.query("SELECT json FROM managed_ai_state WHERE id = 1").first,
              let json = row["json"] ?? nil else { return ManagedLocalState() }
        guard var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let defaults = try JSONSerialization.jsonObject(with: ManagedJSON.encoder().encode(ManagedLocalState())) as? [String: Any] else { throw MinderStoreError.invalidStoredValue("managed_ai_state") }
        for (key, fallback) in defaults where value[key] == nil { value[key] = fallback }
        if var threads = value["threads"] as? [String: [String: Any]] {
            let threadDefaults: [String: Any] = ["localSenderLabels": [:], "dailyActivity": [], "feedback": [], "feedbackRevision": 0, "muted": false, "sourcePresent": true, "lastAttemptFailed": false, "pendingNoAction": false]
            for id in threads.keys {
                for (key, fallback) in threadDefaults where threads[id]?[key] == nil { threads[id]?[key] = fallback }
            }
            value["threads"] = threads
        }
        return try ManagedJSON.decoder().decode(ManagedLocalState.self, from: JSONSerialization.data(withJSONObject: value))
    }
    public func saveManagedState(_ state: ManagedLocalState) throws {
        let json = String(decoding: try ManagedJSON.encoder().encode(state), as: UTF8.self)
        try database.execute("INSERT INTO managed_ai_state(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", [.text(json)])
    }
    public func updateManagedState(_ change: (inout ManagedLocalState) throws -> Void) throws {
        try database.transaction { var state = try managedState(); try change(&state); try saveManagedState(state) }
    }
    public func saveGoal(_ text: String) throws {
        guard text.count <= 2_000 else { throw ManagedAIError.unavailable("Goals can contain at most 2,000 characters.") }
        try updateManagedState { state in
            guard state.goal.text != text else { return }; state.goal = UserGoal(text: text, revision: state.goal.revision + 1); state.revision += 1
            for id in state.recommendations.keys { state.recommendations[id]?.stale = true }
            for id in state.threads.keys { state.threads[id]?.lastAttemptAt = nil }
            state.coverage.reviewed = 0; state.coverage.scanComplete = false
            state.coverage.detail = "Your queue uses previous preferences. Refresh to apply your goal."
        }
    }
    public func managedAction(_ action: RecommendationFeedback.Action, recommendationId: String, days: Int = 1, timeZone: TimeZone = .current, now: Date = Date()) throws {
        try updateManagedState { state in
            guard var rec = state.recommendations[recommendationId], var thread = state.threads[rec.threadId] else { return }
            var until: Date?
            switch action {
            case .done: rec.state = .done; until = rec.content.basis == .relationship ? now.addingTimeInterval(14 * 86_400) : nil
            case .notUseful: rec.state = .dismissed
            case .snoozed:
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                let nextDay = calendar.date(byAdding: .day, value: [1,3,7].contains(days) ? days : 1, to: now)!
                until = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay); rec.state = .snoozed; rec.snoozedUntil = until
            case .muted: thread.muted = true; rec.state = .muted
            case .undone:
                rec.state = .active; rec.snoozedUntil = nil; thread.muted = false
                for otherID in state.recommendations.keys where otherID != rec.id && state.recommendations[otherID]?.threadId == rec.threadId && [.active,.snoozed].contains(state.recommendations[otherID]!.state) {
                    state.recommendations[otherID]?.state = .superseded
                    state.orderedIds.removeAll { $0 == otherID }
                }
                if !state.orderedIds.contains(rec.id) { state.orderedIds.insert(rec.id, at: min(rec.lastRank ?? state.orderedIds.count, state.orderedIds.count)) }
            }
            rec.actionAt = now
            thread.feedback.append(RecommendationFeedback(id: UUID().uuidString, recommendationId: rec.id, action: action, at: now, until: until, substantiveRevision: thread.snapshot.substantiveRevision, basis: rec.content.basis))
            thread.feedbackRevision += 1; thread.stagedRecommendation = nil; thread.pendingNoAction = false
            thread.lastAttemptAt = nil
            state.revision += 1; state.threads[rec.threadId] = thread; state.recommendations[rec.id] = rec
        }
        if recommendationId.hasPrefix("legacy-") {
            let legacyID = String(recommendationId.dropFirst("legacy-".count))
            switch action {
            case .done: try updateSuggestionState(id: legacyID, state: .completed)
            case .notUseful: try updateSuggestionState(id: legacyID, state: .dismissed)
            case .snoozed: try updateSuggestionState(id: legacyID, state: .snoozed, snoozedUntil: managedState().recommendations[recommendationId]?.snoozedUntil)
            case .undone: try updateSuggestionState(id: legacyID, state: .new)
            case .muted: break
            }
        }
    }
    public func unmuteManagedThread(_ id: String) throws {
        try updateManagedState { state in state.threads[id]?.muted = false; state.threads[id]?.cacheKey = nil; state.threads[id]?.feedbackRevision += 1; state.revision += 1 }
    }
    public func clearManagedData(keepPreferences: Bool) throws {
        if keepPreferences {
            let old = try managedState(); var state = ManagedLocalState(); state.goal = old.goal; state.mode = old.mode; state.accountId = old.accountId; state.cacheAccountId = old.cacheAccountId; state.consentVersion = old.consentVersion; state.revision = old.revision + 1
            try saveManagedState(state)
        } else { try database.execute("DELETE FROM managed_ai_state") }
    }
}
public enum ManagedLifecycle {
    public static func eligible(_ thread: ManagedThreadRecord, now: Date) -> Bool {
        if thread.muted { return false }
        let effective = thread.feedback.last
        guard let feedback = effective, feedback.action != .undone else { return true }
        if feedback.action == .snoozed { return (feedback.until ?? .distantFuture) <= now }
        if feedback.action == .done && feedback.basis == .relationship {
            return feedback.substantiveRevision != thread.snapshot.substantiveRevision || (feedback.until ?? feedback.at.addingTimeInterval(14 * 86_400)) <= now
        }
        if feedback.action == .done || feedback.action == .notUseful { return feedback.substantiveRevision != thread.snapshot.substantiveRevision }
        return true
    }
    public static func allows(_ basis: RecommendationBasis, thread: ManagedThreadRecord, now: Date) -> Bool {
        guard basis == .relationship else { return true }
        guard let feedback = thread.feedback.last, feedback.action != .undone else { return true }
        if feedback.action == .done && feedback.basis == .relationship { return (feedback.until ?? feedback.at.addingTimeInterval(14 * 86_400)) <= now }
        return true
    }
    public static func nextAssessment(_ assessment: ThreadAssessment, at date: Date) -> Date {
        if assessment.disposition == .no_action { return date.addingTimeInterval(7 * 86_400) }
        let requested = assessment.recommendation?.reassessAfter ?? date.addingTimeInterval(86_400)
        return max(date.addingTimeInterval(3_600), min(requested, date.addingTimeInterval(86_400)))
    }
    public static func mayNotify(profile: UserProfile, previous: Date?, now: Date) -> Bool {
        guard profile.notificationCadence != .quiet else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: profile.timeZoneIdentifier) ?? .current
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let start = profile.quietHoursStartMinutes, end = profile.quietHoursEndMinutes
        if start < end ? (minutes >= start && minutes < end) : (start != end && (minutes >= start || minutes < end)) { return false }
        guard let previous else { return true }
        switch profile.notificationCadence {
        case .immediately: return true
        case .every15Minutes: return now.timeIntervalSince(previous) >= 15 * 60
        case .hourlyDigest: return now.timeIntervalSince(previous) >= 3_600
        case .dailyDigest: return !calendar.isDate(previous, inSameDayAs: now)
        case .quiet: return false
        }
    }
}

extension MinderStore {
    /// Preserve the previous visible queue during the first managed assessment. These are
    /// explicitly stale legacy items, not fresh AI recommendations or an outage fallback.
    public func seedLegacyManagedQueue(now: Date = Date()) throws {
        var state = try managedState()
        guard state.mode == .managed, !state.legacyMigrationComplete else { return }
        let sources = try fetchSources(), threads = try fetchThreads(), suggestions = try fetchSuggestions()
        let appleSourceIDs = Set(sources.filter { $0.kind == .appleMessages }.map(\.id))
        var seen = Set<String>()
        for suggestion in suggestions where appleSourceIDs.contains(suggestion.sourceId) && [.new,.viewed,.confirmed,.snoozed,.failed,.needsPermission].contains(suggestion.state) {
            guard seen.insert(suggestion.threadId).inserted, let thread = threads.first(where: { $0.id == suggestion.threadId }) else { continue }
            let threadID = ManagedJSON.opaque("messages-thread:" + thread.externalId)
            guard !state.recommendations.values.contains(where: { $0.threadId == threadID }) else { continue }
            let messages = try fetchRecentMessages(threadId: thread.id, limit: 20)
            let context = messages.map { message in ContextMessage(id: ManagedJSON.opaque("message:" + message.externalId), senderId: message.isFromUser ? "local-user" : ManagedJSON.opaque("legacy-sender:" + message.senderLabel), sentAt: message.sentAt, isFromUser: message.isFromUser, body: ManagedJSON.boundedBody(message.body), readState: message.readState, eventKind: message.eventKind, contentAvailability: message.contentAvailability, truncated: message.truncated || message.body.utf8.count > 2000) }
            var snapshot = ThreadSnapshot(threadId: threadID, snapshotId: "", title: thread.title, kind: thread.externalId.contains(";+;") ? .group : .direct, participants: [], messages: context, activityFacts: [], coverage: ContextCoverage(scanComplete: false, observationStart: messages.first?.sentAt ?? now, observationEnd: now, excerptStart: messages.first?.sentAt, excerptEnd: messages.last?.sentAt, moreContextAvailable: true), previousRecommendation: nil, feedback: [], contextPass: .initial)
            try snapshot.stamp()
            var record = ManagedThreadRecord(snapshot: snapshot, localThreadId: thread.id, externalId: thread.externalId)
            record.localDisplayTitle = thread.title
            for message in messages { record.localSenderLabels[message.isFromUser ? "local-user" : ManagedJSON.opaque("legacy-sender:" + message.senderLabel)] = message.senderLabel }
            for previous in suggestions.filter({ $0.threadId == thread.id && [.completed,.dismissed,.snoozed].contains($0.state) }).sorted(by: { $0.updatedAt < $1.updatedAt }) {
                record.feedback.append(RecommendationFeedback(id: "legacy-" + previous.id, recommendationId: previous.id, action: previous.state == .completed ? .done : previous.state == .dismissed ? .notUseful : .snoozed, at: previous.completedAt ?? previous.updatedAt, until: previous.snoozedUntil, substantiveRevision: "legacy-previous-activity", basis: .follow_through))
            }
            let evidenceID = messages.first { $0.id == suggestion.evidence.messageId }.map { ManagedJSON.opaque("message:" + $0.externalId) } ?? "legacy-" + ManagedJSON.opaque(suggestion.evidence.messageId)
            let content = RecommendationContent(headline: String(suggestion.title.prefix(80)), why: "This item was already in your local queue. Managed AI has not reviewed it yet.", nextStep: String(suggestion.action.text.prefix(200)), basis: .follow_through, confidence: .low, urgency: .routine, evidenceRefs: [EvidenceReference(kind: .message, id: evidenceID)], reassessAfter: nil)
            let id = "legacy-" + suggestion.id
            let rec = ThreadRecommendation(id: id, threadId: threadID, content: content, state: suggestion.state == .snoozed ? .snoozed : .active, createdAt: suggestion.createdAt, assessedAt: suggestion.updatedAt, actionAt: nil, snoozedUntil: suggestion.snoozedUntil, substantiveRevision: snapshot.substantiveRevision, goalRevision: state.goal.revision, evidenceMessages: context.filter { $0.id == evidenceID }, evidenceFacts: [], stale: true, notifiedAt: now, lastRank: state.orderedIds.count)
            state.threads[threadID] = record; state.recommendations[id] = rec; state.orderedIds.append(id)
        }
        state.legacyMigrationComplete = true
        try saveManagedState(state)
    }
}
