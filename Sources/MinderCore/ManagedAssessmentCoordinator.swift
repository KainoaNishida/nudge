import Foundation

@MainActor
public final class ManagedAssessmentCoordinator {
    private let store: MinderStore
    private let service: ThreadAssessmentService
    private let collector: ThreadContextCollecting
    public init(store: MinderStore, service: ThreadAssessmentService, collector: ThreadContextCollecting) { self.store = store; self.service = service; self.collector = collector }

    public func refresh(profile: UserProfile, bypassFailureBackoff: Bool = false, progress: @escaping (String) -> Void = { _ in }) async throws {
        let start = try store.managedState()
        guard start.mode == .managed, let account = start.accountId, start.consentVersion > 0 else { throw ManagedAIError.unavailable("Sign in and accept managed AI data sharing in Settings.") }
        let status = try await service.status()
        guard status.access, status.rolloutEnabled else { throw ManagedAIError.unavailable(status.access ? "Managed AI is paused by the owner. Your previous queue is retained." : "This account does not have invited alpha access.") }
        guard start.consentVersion == status.consentVersion else { throw ManagedAIError.unavailable("The data-sharing disclosure changed. Review it in Settings before using managed AI.") }
        guard status.remainingUSD > 0 else { throw ManagedAPIError(code: "quota_exhausted") }
        let now = Date(), runID = UUID().uuidString
        let timeZone = TimeZone(identifier: profile.timeZoneIdentifier) ?? .current
        func checkState() throws {
            let current = try store.managedState()
            guard current.revision == start.revision, current.goal == start.goal, current.accountId == account, current.consentVersion == start.consentVersion, current.mode == .managed else { throw ManagedAIError.staleResult }
        }
        try checkState()
        try store.updateManagedState { state in
            state.status = status; state.coverage.failed = 0; state.coverage.reviewed = 0; state.coverage.unresolved = 0; state.coverage.scanComplete = false
            if state.scanStartedAt == nil { state.scanStartedAt = now; state.scanCursor = 0; state.scanId = UUID().uuidString }
        }
        // Checkpoint each page; interrupted initial imports resume before the next complete scan.
        while true {
            try checkState()
            let state = try store.managedState()
            let source = collector
            let page = try await Task.detached(priority: .utility) { try source.page(after: state.scanCursor, now: now, timeZone: timeZone) }.value
            try checkState()
            let legacy = try store.fetchSuggestions()
            try store.updateManagedState { state in
                for var record in page.records {
                    record.seenScanId = state.scanId
                    if let old = state.threads[record.snapshot.threadId] {
                        record.feedback = old.feedback; record.feedbackRevision = old.feedbackRevision; record.muted = old.muted
                        record.assessment = old.assessment; record.assessedAt = old.assessedAt; record.lastAttemptAt = old.snapshot.snapshotId == record.snapshot.snapshotId ? old.lastAttemptAt : nil; record.cacheKey = old.cacheKey; record.unresolved = old.unresolved; record.lastAttemptFailed = old.lastAttemptFailed
                        if old.snapshot.snapshotId == record.snapshot.snapshotId { record.stagedRecommendation = old.stagedRecommendation; record.pendingNoAction = old.pendingNoAction }
                    } else {
                        for suggestion in legacy.filter({ $0.threadId == record.localThreadId && [.completed,.dismissed,.snoozed].contains($0.state) }).sorted(by: { $0.updatedAt < $1.updatedAt }) {
                            record.feedback.append(RecommendationFeedback(id: "legacy-" + suggestion.id, recommendationId: suggestion.id, action: suggestion.state == .completed ? .done : (suggestion.state == .dismissed ? .notUseful : .snoozed), at: suggestion.completedAt ?? suggestion.updatedAt, until: suggestion.snoozedUntil, substantiveRevision: (record.snapshot.coverage.excerptEnd ?? .distantPast) > (suggestion.completedAt ?? suggestion.updatedAt) ? "legacy-previous-activity" : record.snapshot.substantiveRevision, basis: .follow_through))
                        }
                    }
                    if record.snapshot.previousRecommendation == nil,
                       let previous = legacy.filter({ $0.threadId == record.localThreadId && [.completed,.dismissed].contains($0.state) }).max(by: { $0.updatedAt < $1.updatedAt }) {
                        let previousContent = RecommendationContent(headline: String(previous.title.prefix(80)), why: String("Previously marked \(previous.state == .completed ? "Done" : "Not useful"): \(previous.action.text). Prior source excerpt: \(previous.evidence.snippet)".prefix(600)), nextStep: String(previous.action.text.prefix(200)), basis: .follow_through, confidence: .medium, urgency: .routine,
                            evidenceRefs: [EvidenceReference(kind: .message, id: "legacy-" + ManagedJSON.opaque(previous.evidence.messageId))], reassessAfter: nil)
                        record.snapshot.previousRecommendation = PreviousRecommendation(id: previous.id, content: previousContent)
                    }
                    if let previous = state.recommendations.values.filter({ $0.threadId == record.snapshot.threadId }).max(by: { $0.createdAt < $1.createdAt }) {
                        record.snapshot.previousRecommendation = PreviousRecommendation(id: previous.id, content: previous.content)
                    }
                    record.snapshot.feedback = Array(record.feedback.suffix(100))
                    state.threads[record.snapshot.threadId] = record
                }
                state.scanCursor = page.nextCursor
                state.coverage.total = state.threads.values.filter { !$0.muted && ($0.snapshot.coverage.excerptEnd ?? .distantPast) >= now.addingTimeInterval(-180 * 86_400) }.count
                state.coverage.detail = "Collected \(state.threads.count) conversations from history available on this Mac."
                if page.complete {
                    for id in state.threads.keys where state.threads[id]?.seenScanId != state.scanId {
                        state.threads[id]?.sourcePresent = false
                        state.threads[id]?.unresolved = "This conversation was not available in the current local scan."
                        let cutoff = now.addingTimeInterval(-180 * 86_400)
                        state.threads[id]?.snapshot.messages.removeAll { $0.sentAt < cutoff }
                        state.threads[id]?.dailyActivity.removeAll { $0.date < cutoff }
                        state.threads[id]?.snapshot.activityFacts.removeAll { $0.windowEnd < cutoff }
                    }
                    state.coverage.total = state.threads.values.filter { !$0.muted && $0.sourcePresent }.count
                    state.scanCursor = 0; state.scanStartedAt = nil; state.coverage.scanComplete = true
                }
            }
            progress("Collecting conversation history: \((try store.managedState()).threads.count) threads")
            await Task.yield()
            if page.complete { break }
        }
        try checkState()
        let scan = try store.managedState()
        let eligible = scan.threads.values.filter { !$0.muted && $0.sourcePresent && ($0.snapshot.coverage.excerptEnd ?? .distantPast) >= now.addingTimeInterval(-180 * 86_400) }.sorted { $0.snapshot.threadId < $1.snapshot.threadId }
        func key(_ record: ManagedThreadRecord) -> String {
            ManagedJSON.opaque([account, String(start.goal.revision), String(start.consentVersion),record.snapshot.snapshotId,String(record.feedbackRevision),status.model,status.assessPromptVersion,"1"].joined(separator: "|"))
        }
        let pending = eligible.filter { record in
            guard ManagedLifecycle.eligible(record, now: now) else { return false }
            if !bypassFailureBackoff, record.lastAttemptFailed, let lastAttempt = record.lastAttemptAt, now < lastAttempt.addingTimeInterval(6 * 3_600) { return false }
            if record.cacheKey != key(record) { return true }
            guard let date = record.assessedAt, let assessment = record.assessment else { return true }
            return now >= ManagedLifecycle.nextAssessment(assessment, at: date)
        }
        try store.updateManagedState { state in state.coverage.reviewed = eligible.count - pending.count; state.coverage.unresolved = eligible.filter { record in !pending.contains(where: { $0.snapshot.threadId == record.snapshot.threadId }) && record.unresolved != nil }.count }
        let localUser = LocalUserContext(displayName: String(profile.displayName.prefix(200)), aliases: Array(UserIdentityAliases.aliases(for: profile).filter { !ContactHandleNormalizer.looksLikeRawHandle($0) }.prefix(20)).map { String($0.prefix(200)) })
        var remaining = pending
        while !remaining.isEmpty {
            try checkState()
            var batch: [ManagedThreadRecord] = []
            while !remaining.isEmpty && batch.count < 4 {
                let candidate = remaining[0]
                let test = AssessmentRequest(runId: runID, observedAt: now, timeZone: timeZone.identifier, goal: start.goal, localUser: localUser, threads: (batch + [candidate]).map(\.snapshot))
                if try ManagedJSON.wireData(test).count > 256 * 1024 {
                    if batch.isEmpty { remaining.removeFirst(); try markUnresolved([candidate.snapshot.threadId], "Conversation exceeds the request limit.", failed: true) }
                    break
                }
                batch.append(remaining.removeFirst())
            }
            if batch.isEmpty { continue }
            progress("Assessing \((try store.managedState()).coverage.reviewed) of \(eligible.count) conversations")
            let request = AssessmentRequest(runId: runID, observedAt: now, timeZone: timeZone.identifier, goal: start.goal, localUser: localUser, threads: batch.map(\.snapshot))
            do {
                let response = try await service.assess(request)
                try ManagedContract.validate(response, for: request); try checkState()
                guard response.model == status.model, response.promptVersion == status.assessPromptVersion else { throw ManagedAIError.staleResult }
                for decision in response.decisions {
                    let record = batch.first { $0.snapshot.threadId == decision.threadId }!
                    if decision.disposition == .needs_context && record.snapshot.coverage.moreContextAvailable {
                        var expansionRecord = record
                        // Supply pinned prior evidence to the expansion collector without sending local routing IDs.
                        expansionRecord.stagedRecommendation = scan.recommendations.values.filter { $0.threadId == decision.threadId }.max { $0.createdAt < $1.createdAt }
                        let source = collector
                        let expansionInput = expansionRecord
                        let expanded = try await Task.detached(priority: .utility) { try source.expand(expansionInput, now: now) }.value
                        try checkState()
                        let expandedRequest = AssessmentRequest(runId: runID, observedAt: now, timeZone: timeZone.identifier, goal: start.goal, localUser: localUser, threads: [expanded])
                        guard try ManagedJSON.wireData(expandedRequest).count <= 256 * 1024 else { throw ManagedAIError.invalidResponse }
                        let expandedResponse = try await service.assess(expandedRequest)
                        try ManagedContract.validate(expandedResponse, for: expandedRequest); try checkState()
                        guard expandedResponse.model == status.model, expandedResponse.promptVersion == status.assessPromptVersion else { throw ManagedAIError.staleResult }
                        try stage(expandedResponse.decisions[0], snapshot: expanded, key: key(record), goal: start.goal, now: now)
                    } else { try stage(decision, snapshot: record.snapshot, key: key(record), goal: start.goal, now: now) }
                }
            } catch ManagedAIError.staleResult { throw ManagedAIError.staleResult }
            catch {
                try checkState(); try markUnresolved(batch.map { $0.snapshot.threadId }, error.localizedDescription, failed: true, attemptedAt: now)
                // Stop on systemic failures; preserve successful staging for a later ranking retry.
                if !(error is DecodingError) {
                    try markUnresolved(remaining.map { $0.snapshot.threadId }, "Not yet assessed because cloud analysis stopped.", failed: true); remaining = []
                }
            }
        }
        try checkState()
        if let latestStatus = try? await service.status() { try checkState(); try store.updateManagedState { $0.status = latestStatus } }
        let staged = try store.managedState()
        var proposed = Dictionary(uniqueKeysWithValues: staged.recommendations.values.filter { [.active,.snoozed].contains($0.state) && !(staged.threads[$0.threadId]?.muted ?? false) }.map { ($0.threadId,$0) })
        for record in staged.threads.values {
            if record.pendingNoAction { proposed.removeValue(forKey: record.snapshot.threadId) }
            if let rec = record.stagedRecommendation { proposed[record.snapshot.threadId] = rec }
        }
        let records = proposed.values.sorted { $0.id < $1.id }.map { rec in RankedRecommendation(id: rec.id, content: rec.content, evidenceSummaries: rec.evidenceText().map { String($0.prefix(240)) }, lastActivityAt: staged.threads[rec.threadId]?.snapshot.coverage.excerptEnd ?? rec.assessedAt, assessedAt: rec.assessedAt, previousOrder: staged.orderedIds.firstIndex(of: rec.id)) }
        let changed = staged.threads.values.contains { $0.stagedRecommendation != nil || $0.pendingNoAction }
        let ordered: [String]
        if changed {
            progress("Ranking \(records.count) recommendations")
            ordered = try await rankAll(records, runID: runID, goal: start.goal, now: now, status: status, account: account, consent: start.consentVersion, revision: start.revision)
        } else { ordered = staged.orderedIds.filter { id in proposed.values.contains { $0.id == id } } }
        try checkState()
        // Verify mutable source state again before publication; opening Messages can update reads mid-run.
        for record in eligible where staged.threads[record.snapshot.threadId]?.stagedRecommendation != nil || staged.threads[record.snapshot.threadId]?.pendingNoAction == true {
            let source = collector
            let current = try await Task.detached(priority: .utility) { try source.isCurrent(record) }.value
            if !current { throw ManagedAIError.staleResult }
        }
        try checkState()
        try store.updateManagedState { state in
            for record in state.threads.values {
                if record.pendingNoAction {
                    for id in state.recommendations.keys where state.recommendations[id]?.threadId == record.snapshot.threadId && [.active,.snoozed].contains(state.recommendations[id]!.state) { state.recommendations[id]?.state = .superseded }
                }
                if let rec = record.stagedRecommendation { state.recommendations[rec.id] = rec }
                state.threads[record.snapshot.threadId]?.stagedRecommendation = nil; state.threads[record.snapshot.threadId]?.pendingNoAction = false
            }
            state.orderedIds = ordered
            state.rankingPassCache.removeAll()
            for (rank,id) in ordered.enumerated() { state.recommendations[id]?.lastRank = rank }
            for id in ordered {
                if state.threads[state.recommendations[id]!.threadId]?.unresolved != nil { state.recommendations[id]?.stale = true }
            }
            let missingActive = Set(ordered.compactMap { id -> String? in
                guard let rec = state.recommendations[id], state.threads[rec.threadId]?.sourcePresent == false else { return nil }
                return rec.threadId
            }).count
            let currentRecords = state.threads.values.filter { $0.sourcePresent && !$0.muted }
            state.coverage.total = currentRecords.count + missingActive
            state.coverage.failed = currentRecords.filter(\.lastAttemptFailed).count + missingActive
            state.coverage.unresolved = currentRecords.filter { !$0.lastAttemptFailed && $0.unresolved != nil }.count
            state.coverage.reviewed = currentRecords.filter { !$0.lastAttemptFailed && ($0.assessment != nil || !ManagedLifecycle.eligible($0, now: now)) }.count
            if state.coverage.isComplete { state.coverage.lastSuccessAt = now }
            state.coverage.detail = state.coverage.isComplete ? "Reviewed \(state.coverage.total) conversations on this Mac." : "Reviewed \(state.coverage.reviewed) of \(state.coverage.total); \(state.coverage.unresolved) uncertain, \(state.coverage.failed) failed or pending. Previous recommendations are retained."
            if let failure = currentRecords.filter({ $0.lastAttemptFailed }).compactMap(\.unresolved).sorted().first {
                state.coverage.detail += " " + failure
            }
        }
    }
    private func markUnresolved(_ ids: [String], _ reason: String, failed: Bool, attemptedAt: Date? = nil) throws {
        try store.updateManagedState { state in
            for id in ids {
                state.threads[id]?.unresolved = reason; state.threads[id]?.lastAttemptFailed = failed
                state.threads[id]?.stagedRecommendation = nil; state.threads[id]?.pendingNoAction = false
                if let attemptedAt { state.threads[id]?.lastAttemptAt = attemptedAt }
                if failed { state.threads[id]?.cacheKey = nil }
            }
            if failed { state.coverage.failed += ids.count } else { state.coverage.unresolved += ids.count }
        }
    }
    private func stage(_ decision: ThreadAssessment, snapshot: ThreadSnapshot, key: String, goal: UserGoal, now: Date) throws {
        try store.updateManagedState { state in
            guard var record = state.threads[decision.threadId], record.snapshot.snapshotId == decision.snapshotId else { throw ManagedAIError.staleResult }
            record.assessment = decision; record.cacheKey = key; record.assessedAt = now; record.lastAttemptAt = now; record.unresolved = nil; record.lastAttemptFailed = false; record.pendingNoAction = false
            state.coverage.reviewed += 1
            switch decision.disposition {
            case .no_action: record.pendingNoAction = true; record.stagedRecommendation = nil
            case .needs_context: record.unresolved = decision.contextRequest?.reason ?? "More context is needed."; state.coverage.unresolved += 1
            case .recommend:
                guard let content = decision.recommendation, content.confidence != .low else { record.unresolved = "The evidence is not sufficiently supported."; state.coverage.unresolved += 1; state.threads[decision.threadId] = record; return }
                guard ManagedLifecycle.allows(content.basis, thread: record, now: now) else {
                    record.stagedRecommendation = nil; state.threads[decision.threadId] = record; return
                }
                let existing = state.recommendations.values.first { $0.threadId == decision.threadId && [.active,.snoozed].contains($0.state) }
                let rec = ThreadRecommendation(id: existing?.id ?? UUID().uuidString, threadId: decision.threadId, content: content, state: existing?.state ?? .active, createdAt: existing?.createdAt ?? now, assessedAt: now, actionAt: existing?.actionAt, snoozedUntil: existing?.snoozedUntil, substantiveRevision: record.snapshot.substantiveRevision, goalRevision: goal.revision,
                    evidenceMessages: snapshot.messages.filter { message in content.evidenceRefs.contains { $0.kind == .message && $0.id == message.id } }, evidenceFacts: snapshot.activityFacts.filter { fact in content.evidenceRefs.contains { $0.kind == .activity && $0.id == fact.id } }, stale: false, notifiedAt: existing?.notifiedAt)
                // Reassessment with unchanged priority facts does not purchase another ranking call.
                if let existing, existing.content == rec.content, existing.substantiveRevision == rec.substantiveRevision, existing.goalRevision == goal.revision {
                    state.recommendations[existing.id]?.assessedAt = now; state.recommendations[existing.id]?.stale = false
                } else { record.stagedRecommendation = rec }
            }
            state.threads[decision.threadId] = record
        }
    }
    private func rankAll(_ records: [RankedRecommendation], runID: String, goal: UserGoal, now: Date, status: ManagedAIStatus, account: String, consent: Int, revision: Int) async throws -> [String] {
        if records.isEmpty { return [] }
        func rank(_ items: [RankedRecommendation]) async throws -> [RankedRecommendation] {
            let stateBefore = try store.managedState()
            guard stateBefore.goal == goal, stateBefore.mode == .managed, stateBefore.accountId == account, stateBefore.consentVersion == consent, stateBefore.revision == revision else { throw ManagedAIError.staleResult }
            let cacheKey = ManagedJSON.opaque((stateBefore.accountId ?? "") + status.model + status.rankPromptVersion + String(goal.revision) + (try ManagedJSON.hash(items)))
            if let ids = stateBefore.rankingPassCache[cacheKey] {
                try ManagedContract.validateOrder(ids, expected: items.map(\.id))
                return ids.map { id in items.first { $0.id == id }! }
            }
            let request = RankingRequest(runId: runID, observedAt: now, goal: goal, recommendations: items)
            guard try ManagedJSON.wireData(request).count <= 256 * 1024 else { throw ManagedAIError.invalidResponse }
            let response = try await service.rank(request)
            guard response.schemaVersion == 1, response.runId == runID, response.requestId == request.requestId, response.model == status.model, response.promptVersion == status.rankPromptVersion else { throw ManagedAIError.invalidResponse }
            try ManagedContract.validateOrder(response.orderedRecommendationIds, expected: items.map(\.id))
            try store.updateManagedState { state in
                guard state.revision == stateBefore.revision, state.accountId == stateBefore.accountId, state.goal == goal else { throw ManagedAIError.staleResult }
                state.rankingPassCache[cacheKey] = response.orderedRecommendationIds
            }
            return response.orderedRecommendationIds.map { id in items.first { $0.id == id }! }
        }
        // Bounded sorted runs, then pairwise AI merge. Every item survives; no top-N truncation.
        var runs: [[RankedRecommendation]] = []
        for offset in stride(from: 0, to: records.count, by: 8) { runs.append(try await rank(Array(records[offset..<min(offset+8,records.count)]))) }
        while runs.count > 1 {
            var mergedRuns: [[RankedRecommendation]] = []
            for index in stride(from: 0, to: runs.count, by: 2) {
                if index+1 == runs.count { mergedRuns.append(runs[index]); continue }
                var left = runs[index], right = runs[index+1], merged: [RankedRecommendation] = []
                while !left.isEmpty && !right.isEmpty {
                    let ordered = try await rank([left[0],right[0]])
                    if ordered[0].id == left[0].id { merged.append(left.removeFirst()) } else { merged.append(right.removeFirst()) }
                }
                mergedRuns.append(merged + left + right)
            }; runs = mergedRuns
        }
        let ids = runs[0].map(\.id); try ManagedContract.validateOrder(ids, expected: records.map(\.id)); return ids
    }
}
