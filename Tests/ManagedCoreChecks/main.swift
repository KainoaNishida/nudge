import Foundation
@testable import MinderCore

func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw ManagedAIError.unavailable("CHECK FAILED: " + message) }
}
func rejects(_ message: String, _ block: () throws -> Void) throws {
    do { try block() } catch { return }; throw ManagedAIError.unavailable("CHECK FAILED (accepted invalid data): " + message)
}
func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
    try ManagedJSON.decoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: "contracts/fixtures/" + name + ".json")))
}
final class FakeCollector: ThreadContextCollecting {
    var records: [ManagedThreadRecord]; var expansions = 0; var current = true
    init(_ records: [ManagedThreadRecord]) { self.records = records }
    func page(after: Int, now: Date, timeZone: TimeZone) throws -> ManagedScanPage { ManagedScanPage(records: records, nextCursor: 1, complete: true) }
    func expand(_ record: ManagedThreadRecord, now: Date) throws -> ThreadSnapshot { expansions += 1; var snapshot = record.snapshot; snapshot.contextPass = .expanded; return snapshot }
    func isCurrent(_ record: ManagedThreadRecord) throws -> Bool { current }
}
final class FakeService: ThreadAssessmentService {
    var assessmentCalls = 0; var rankingCalls = 0; var disposition: AssessmentDisposition = .recommend
    var failAssessment = false; var failRanking = false; var duringAssessment: (() throws -> Void)?
    var content: RecommendationContent
    init(_ content: RecommendationContent) { self.content = content }
    func status() async throws -> ManagedAIStatus { ManagedAIStatus(schemaVersion: 1, access: true, rolloutEnabled: true, remainingUSD: 5, resetsAt: Date().addingTimeInterval(86_400), model: "test-model", assessPromptVersion: "assess-v1", rankPromptVersion: "rank-v1", consentVersion: 1) }
    func assess(_ request: AssessmentRequest) async throws -> AssessmentResponse {
        assessmentCalls += 1; try duringAssessment?(); if failAssessment { throw ManagedAIError.unavailable("Provider unavailable") }
        return AssessmentResponse(schemaVersion: 1, requestId: request.requestId, runId: request.runId, model: "test-model", promptVersion: "assess-v1", usage: AIUsage(inputTokens: 1, outputTokens: 1, thinkingTokens: 1), durationMs: 1, decisions: request.threads.map { t in
            var c = content; c.evidenceRefs = [EvidenceReference(kind: .message, id: t.messages[0].id)]
            return ThreadAssessment(threadId: t.threadId, snapshotId: t.snapshotId, disposition: disposition, decisionSummary: "Synthetic evidence", recommendation: disposition == .recommend ? c : nil, contextRequest: disposition == .needs_context ? ContextRequest(reason: "More context is needed", totalMessages: 80) : nil)
        })
    }
    func rank(_ request: RankingRequest) async throws -> RankingResponse {
        rankingCalls += 1; if failRanking { throw ManagedAIError.invalidResponse }
        return RankingResponse(schemaVersion: 1, requestId: request.requestId, runId: request.runId, model: "test-model", promptVersion: "rank-v1", usage: AIUsage(inputTokens: 1, outputTokens: 1, thinkingTokens: 1), durationMs: 1, orderedRecommendationIds: request.recommendations.map(\.id).sorted())
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nudge-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request: AssessmentRequest = try fixture("assess-request", as: AssessmentRequest.self)
        let response: AssessmentResponse = try fixture("assess-response", as: AssessmentResponse.self)
        try ManagedContract.validate(response, for: request)
        let wire = try ManagedJSON.wireData(request)
        try wire.write(to: URL(fileURLWithPath: ".build/swift-contract-request.json"))
        let object = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        let threadWire = (object["threads"] as! [[String: Any]])[0]
        try expect(threadWire["previousRecommendation"] is NSNull, "nullable wire keys")
        try rejects("invalid permutation") { try ManagedContract.validateOrder(["a","a"], expected: ["a","b"]) }
        var invalid = response; invalid.decisions[0].recommendation?.evidenceRefs[0].id = "invented"
        try rejects("invented evidence") { try ManagedContract.validate(invalid, for: request) }
        var snapshot = request.threads[0]; snapshot.coverage.excerptEnd = Date(); snapshot.messages[0].sentAt = Date(); try snapshot.stamp()
        let record = ManagedThreadRecord(snapshot: snapshot, localThreadId: "legacy-thread", externalId: "iMessage;-;synthetic")
        let store = try MinderStore(databaseURL: root.appendingPathComponent("app.sqlite"))
        var state = ManagedLocalState(); state.accountId = "account-a"; state.mode = .managed; state.consentVersion = 1; try store.saveManagedState(state)
        var legacyStateJSON = try JSONSerialization.jsonObject(with: ManagedJSON.encoder().encode(state)) as! [String: Any]
        legacyStateJSON.removeValue(forKey: "historyWindowDays")
        let legacyStateText = String(decoding: try JSONSerialization.data(withJSONObject: legacyStateJSON), as: UTF8.self)
        try store.database.execute("UPDATE managed_ai_state SET json=? WHERE id=1", [.text(legacyStateText)])
        try expect(store.managedState().historyWindowDays == 50, "managed history defaults to 50 days")
        let collector = FakeCollector([record]); let service = FakeService(response.decisions[0].recommendation!)
        let coordinator = ManagedAssessmentCoordinator(store: store, service: service, collector: collector)
        let profile = UserProfile(displayName: "Kai")
        try await coordinator.refresh(profile: profile)
        let first = try store.managedState(); try expect(first.visible().count == 1, "initial recommendation appears")
        var noAction = first.threads[snapshot.threadId]!.assessment!
        noAction.disposition = .no_action; noAction.recommendation = nil
        try expect(ManagedLifecycle.nextAssessment(noAction, at: Date(timeIntervalSince1970: 0)) == Date(timeIntervalSince1970: 7 * 86_400), "unchanged no-action threads wait one week")
        let id = first.visible()[0].id
        try await coordinator.refresh(profile: profile); try expect(service.assessmentCalls == 1 && service.rankingCalls == 1, "unchanged cache avoids provider calls")
        try store.updateManagedState { $0.recommendations[id]?.notifiedAt = Date() }
        service.content.why = "The wording changed, but the supporting request is the same."
        try store.saveGoal("Follow through on commitments")
        try await coordinator.refresh(profile: profile)
        try expect(store.managedState().visible().first?.id == id && store.managedState().recommendations[id]?.notifiedAt != nil, "rewording and reranking preserve notification identity")
        try store.saveGoal("Follow through"); service.failAssessment = true; collector.current = false
        try await coordinator.refresh(profile: profile)
        try expect(store.managedState().visible().first?.id == id, "provider outage preserves queue")
        try expect(!store.managedState().coverage.isComplete, "outage cannot report empty complete")
        try expect(store.managedState().coverage.detail.contains("Provider unavailable"), "unchanged retained items cannot overwrite a provider failure with a stale-result error")
        let failedCalls = service.assessmentCalls
        try await coordinator.refresh(profile: profile)
        try expect(service.assessmentCalls == failedCalls, "failed assessment waits before an automatic retry")
        collector.current = true
        service.failAssessment = false; service.failRanking = true
        do { try await coordinator.refresh(profile: profile, bypassFailureBackoff: true) } catch {}
        try expect(store.managedState().visible().first?.id == id, "rank failure preserves queue")
        try expect(store.managedState().threads[snapshot.threadId]?.stagedRecommendation != nil, "rank failure retains staged result")
        service.failRanking = false; try await coordinator.refresh(profile: profile)
        try store.managedAction(.done, recommendationId: id)
        try expect(store.managedState().visible().isEmpty, "Done removes item")
        let calls = service.assessmentCalls; try await coordinator.refresh(profile: profile)
        try expect(service.assessmentCalls == calls, "refresh cannot recreate a completed need")
        try store.managedAction(.undone, recommendationId: id); try expect(store.managedState().visible().count == 1, "Undo restores Done")
        try store.managedAction(.snoozed, recommendationId: id, days: 3, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let snooze = try store.managedState().recommendations[id]!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        try expect(cal.component(.hour, from: snooze.snoozedUntil!) == 9, "snooze returns at 9 local time")
        collector.records[0].snapshot.messages[0].body += " New substantive message"; try collector.records[0].snapshot.stamp()
        try await coordinator.refresh(profile: profile); try expect(store.managedState().visible().isEmpty, "new messages cannot override snooze")
        try store.managedAction(.undone, recommendationId: id)
        try store.saveGoal("New goal")
        service.duringAssessment = { try store.managedAction(.done, recommendationId: id) }
        do { try await coordinator.refresh(profile: profile); throw ManagedAIError.unavailable("Stale result accepted") } catch ManagedAIError.staleResult {}
        try expect(store.managedState().visible().isEmpty, "in-flight result cannot overwrite Done")
        service.duringAssessment = nil
        var relationship = record; let at = Date()
        relationship.feedback = [RecommendationFeedback(id: "f", recommendationId: "r", action: .done, at: at, until: at.addingTimeInterval(14*86_400), substantiveRevision: snapshot.substantiveRevision, basis: .relationship)]
        try expect(!ManagedLifecycle.eligible(relationship, now: at.addingTimeInterval(14*86_400-1)), "relationship suppressed before day 14")
        try expect(ManagedLifecycle.eligible(relationship, now: at.addingTimeInterval(14*86_400)), "day 14 permits reassessment")
        relationship.feedback[0].action = .notUseful; relationship.feedback[0].until = nil
        try expect(!ManagedLifecycle.eligible(relationship, now: at.addingTimeInterval(30*86_400)), "Not useful survives passage of time")
        var newObligation = relationship
        newObligation.feedback[0].action = .done; newObligation.feedback[0].until = at.addingTimeInterval(14*86_400)
        newObligation.snapshot.messages[0].body += " Please send this tonight."
        try expect(ManagedLifecycle.eligible(newObligation, now: at), "relationship cooldown does not hide a new obligation")
        try expect(!ManagedLifecycle.allows(.relationship, thread: newObligation, now: at), "new activity still cannot bypass relationship cooldown")
        var quietProfile = profile; quietProfile.timeZoneIdentifier = "America/Los_Angeles"; quietProfile.quietHoursStartMinutes = 22*60; quietProfile.quietHoursEndMinutes = 7*60
        let night = ISO8601DateFormatter().date(from: "2026-10-02T06:00:00Z")!
        try expect(!ManagedLifecycle.mayNotify(profile: quietProfile, previous: nil, now: night), "quiet hours cross midnight correctly")
        quietProfile.notificationCadence = .hourlyDigest
        let day = night.addingTimeInterval(12*3600)
        try expect(!ManagedLifecycle.mayNotify(profile: quietProfile, previous: day.addingTimeInterval(-3500), now: day), "hourly digest waits a full hour")
        quietProfile.notificationCadence = .dailyDigest
        try expect(!ManagedLifecycle.mayNotify(profile: quietProfile, previous: day.addingTimeInterval(-3600), now: day), "daily digest stays within one local day")
        try await sourceChecks(root: root)
        try await historyWindowChecks(root: root, record: record, content: response.decisions[0].recommendation!)
        try unknownSenderChecks(root: root)
        try dateDecodingChecks()
        try sessionStoreChecks()
        try petAttentionChecks()
        try await staleChecks(root: root, record: record, content: response.decisions[0].recommendation!)
        try await expansionAndRankingChecks(root: root, record: record, content: response.decisions[0].recommendation!)
        print("Managed Swift checks passed: contract, configurable history, cache, staging, outages, stale results, lifecycle, read state, collection, expansion, and complete ranking.")
    }
    @MainActor static func historyWindowChecks(root: URL, record: ManagedThreadRecord, content: RecommendationContent) async throws {
        let store = try MinderStore(databaseURL: root.appendingPathComponent("history-window.sqlite"))
        var state = ManagedLocalState(); state.mode = .managed; state.accountId = "a"; state.consentVersion = 1; state.historyWindowDays = 90
        try store.saveManagedState(state)
        var old = record
        let oldDate = Date().addingTimeInterval(-60 * 86_400)
        old.snapshot.messages[0].sentAt = oldDate
        old.snapshot.coverage.observationStart = oldDate.addingTimeInterval(-86_400)
        old.snapshot.coverage.excerptStart = oldDate
        old.snapshot.coverage.excerptEnd = oldDate
        try old.snapshot.stamp()
        let collector = FakeCollector([old]), service = FakeService(content)
        let coordinator = ManagedAssessmentCoordinator(store: store, service: service, collector: collector)
        let profile = UserProfile(displayName: "Kai")
        try await coordinator.refresh(profile: profile)
        try expect(store.managedState().visible().count == 1, "90-day scope can recommend a 60-day-old conversation")
        try store.saveHistoryWindowDays(50)
        try expect(store.managedState().visible().isEmpty, "narrowing scope hides older AI items immediately")
        try await coordinator.refresh(profile: profile)
        try expect(store.managedState().coverage.total == 0 && service.assessmentCalls == 1, "narrow scope does not reassess older conversations")
        try store.saveHistoryWindowDays(90)
        try await coordinator.refresh(profile: profile)
        try expect(store.managedState().visible().count == 1, "widening scope restores still-valid ranked recommendations")
    }
    static func petAttentionChecks() throws {
        var tracker = PetAttentionTracker()
        tracker.observe(["thread-a": "message-1"], queueIsVisible: false)
        try expect(!tracker.hasPendingChange, "old queue items do not alert at launch")
        tracker.observe(["thread-a": "message-1"], queueIsVisible: false)
        try expect(!tracker.hasPendingChange, "unchanged or reranked recommendations stay quiet")
        tracker.observe(["thread-a": "message-2"], queueIsVisible: false)
        try expect(tracker.hasPendingChange, "substantively updated thread wakes the pet")
        var profile = UserProfile(displayName: "Kai")
        profile.notificationCadence = .every15Minutes
        let now = Date()
        try expect(!tracker.shouldSignal(profile: profile, lastSignalAt: now.addingTimeInterval(-14 * 60), now: now), "15-minute cadence holds pending changes")
        try expect(tracker.shouldSignal(profile: profile, lastSignalAt: now.addingTimeInterval(-15 * 60), now: now), "15-minute cadence releases pending changes")
        tracker.acknowledge()
        try expect(!tracker.hasPendingChange, "opening Nudge acknowledges the signal")
        tracker.observe(["thread-a": "message-2", "thread-b": "message-1"], queueIsVisible: true)
        try expect(!tracker.hasPendingChange, "visible queue does not cause a second notification")
        tracker.observe(["thread-a": "message-2", "thread-b": "message-1"], queueIsVisible: false)
        try expect(!tracker.hasPendingChange, "a refresh with the same items stays quiet")
        tracker.observe(["thread-a": "message-2", "thread-b": "message-1", "thread-c": "message-1"], queueIsVisible: false)
        tracker.observe(["thread-a": "message-2", "thread-b": "message-1"], queueIsVisible: false)
        try expect(!tracker.hasPendingChange, "resolved items cannot trigger a delayed pet alert")
        tracker.observe(["thread-a": "message-3", "thread-b": "message-1"], queueIsVisible: false)
        profile.notificationCadence = .quiet
        try expect(!tracker.shouldSignal(profile: profile, lastSignalAt: nil, now: now), "Quiet mode suppresses the pet alert")
    }
    static func dateDecodingChecks() throws {
        let values = ["2026-10-01T12:34:56Z", "2026-10-01T12:34:56.125Z", "2026-10-01T05:34:56-07:00"]
        let data = try JSONEncoder().encode((0..<30_000).map { values[$0 % values.count] })
        let start = Date()
        let dates = try ManagedJSON.decoder().decode([Date].self, from: data)
        let elapsed = Date().timeIntervalSince(start)
        try expect(dates.count == 30_000 && dates[0] == dates[2], "date parsing preserves UTC and offset timestamps")
        try expect(abs(dates[1].timeIntervalSince(dates[0]) - 0.125) < 0.00001, "fractional timestamps remain supported")
        try rejects("invalid date") { _ = try ManagedJSON.decoder().decode(Date.self, from: Data("\"not-a-date\"".utf8)) }
        // A generous regression guard: per-value ICU construction previously took
        // tens of seconds and froze the interface for real local history sizes.
        try expect(elapsed < 5, "30,000 dates decode without blocking for seconds")
        print("Decoded 30,000 history dates in \(String(format: "%.3f", elapsed))s.")
    }
    @MainActor static func unknownSenderChecks(root: URL) throws {
        let url = root.appendingPathComponent("unknown-sender.sqlite")
        let db = try SQLiteDatabase(url: url)
        try db.execute("CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,is_read INTEGER,associated_message_type INTEGER,item_type INTEGER)")
        try db.execute("CREATE TABLE chat(guid TEXT,display_name TEXT)")
        try db.execute("CREATE TABLE handle(id TEXT)")
        try db.execute("CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER)")
        try db.execute("INSERT INTO handle VALUES('person@example.test')")
        try db.execute("INSERT INTO chat VALUES('iMessage;+;event','System event')")
        try db.execute("INSERT INTO chat VALUES('iMessage;+;history','Older system event')")
        let now = Date()
        let time = Int(AppleMessagesDateCodec.messageDateValue(from: now.addingTimeInterval(-3600)))
        try db.execute("INSERT INTO message VALUES('event',NULL,?,0,NULL,1,0,1)", [.int(time)])
        try db.execute("INSERT INTO chat_message_join VALUES(1,1)")
        try db.execute("INSERT INTO chat_message_join VALUES(2,1)")
        for n in 2...21 {
            try db.execute("INSERT INTO message VALUES(?,?,?,0,1,1,0,0)", [.text("reply-\(n)"),.text("Synthetic message"),.int(time+n*1_000_000_000)])
            try db.execute("INSERT INTO chat_message_join VALUES(2,?)", [.int(n)])
        }
        let collector = ManagedMessagesCollector(databaseURL: url)
        let page = try collector.page(after: 0, now: now, timeZone: .current)
        let event = page.records.first { $0.snapshot.title == "System event" }!.snapshot
        let message = event.messages[0]
        try expect(message.eventKind == .system && message.contentAvailability == .unavailable, "senderless system events retain their incomplete context")
        try expect(event.participants.contains { $0.id == message.senderId && $0.displayName == "Unknown participant" && !$0.isLocalUser }, "every initial sender has an explicit participant")
        let history = page.records.first { $0.snapshot.title == "Older system event" }!
        let expanded = try collector.expand(history, now: now)
        try expect(expanded.messages.count == 21, "expansion includes the older senderless event")
        try expect(expanded.messages.allSatisfy { m in expanded.participants.contains { $0.id == m.senderId } }, "expansion supplies participants for newly included events")
        let local = LocalUserContext(displayName: "Kai", aliases: [])
        let initialRequest = AssessmentRequest(runId: UUID().uuidString, observedAt: now, timeZone: "UTC", goal: UserGoal(), localUser: local, threads: page.records.map(\.snapshot))
        let expandedRequest = AssessmentRequest(runId: UUID().uuidString, observedAt: now, timeZone: "UTC", goal: UserGoal(), localUser: local, threads: [expanded])
        try ManagedJSON.wireData(initialRequest).write(to: URL(fileURLWithPath: ".build/swift-sender-request.json"))
        try ManagedJSON.wireData(expandedRequest).write(to: URL(fileURLWithPath: ".build/swift-expanded-sender-request.json"))
    }
    @MainActor static func sourceChecks(root: URL) async throws {
        let url = root.appendingPathComponent("messages.sqlite")
        let db = try SQLiteDatabase(url: url)
        try db.execute("CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,is_read INTEGER,associated_message_type INTEGER)")
        try db.execute("CREATE TABLE chat(guid TEXT,display_name TEXT)")
        try db.execute("CREATE TABLE handle(id TEXT)")
        try db.execute("CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER)")
        try db.execute("INSERT INTO handle VALUES('person@example.test')")
        try db.execute("INSERT INTO chat VALUES('iMessage;+;busy','Busy')")
        try db.execute("INSERT INTO chat VALUES('iMessage;-;quiet','Quiet')")
        try db.execute("INSERT INTO chat VALUES('iMessage;-;old','Older than default window')")
        let now = Date(); let timestamp = Int(AppleMessagesDateCodec.messageDateValue(from: now.addingTimeInterval(-3600)))
        for n in 1...600 {
            try db.execute("INSERT INTO message VALUES(?,?,?,0,1,0,0)",[.text("busy-\(n)"),.text("Message \(n)"),.int(timestamp+n)])
            try db.execute("INSERT INTO chat_message_join VALUES(1,?)",[.int(n)])
        }
        try db.execute("INSERT INTO message VALUES('quiet','Please reply',?,0,1,0,0)",[.int(timestamp-3600*1_000_000_000)])
        try db.execute("INSERT INTO chat_message_join VALUES(2,601)")
        let oldTime = Int(AppleMessagesDateCodec.messageDateValue(from: now.addingTimeInterval(-60 * 86_400)))
        try db.execute("INSERT INTO message VALUES('old','Old follow-up',?,0,1,0,0)",[.int(oldTime)])
        try db.execute("INSERT INTO chat_message_join VALUES(3,602)")
        try db.execute("INSERT INTO message VALUES('quiet-old','Older quiet context',?,0,1,0,0)",[.int(oldTime)])
        try db.execute("INSERT INTO chat_message_join VALUES(2,603)")
        let collector = ManagedMessagesCollector(databaseURL: url)
        let page = try collector.page(after: 0, now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        try expect(page.records.count == 2, "50-day default excludes older threads without crowding out quiet recent ones")
        let wider = try ManagedMessagesCollector(databaseURL: url, historyWindowDays: 90).page(after: 0, now: now, timeZone: .current)
        try expect(wider.records.count == 3, "a wider user setting includes older conversations")
        try expect(page.records.first { $0.snapshot.title == "Quiet" }?.snapshot.messages.count == 1, "default context omits messages beyond 50 days")
        try expect(wider.records.first { $0.snapshot.title == "Quiet" }?.snapshot.messages.count == 2, "wider context includes older messages")
        let busy = page.records.first { $0.snapshot.title == "Busy" }!
        let roundTripped = try ManagedJSON.decoder().decode(ManagedThreadRecord.self, from: ManagedJSON.encoder().encode(busy))
        try expect(collector.isCurrent(roundTripped), "snapshot timestamps survive SQLite JSON round-trip without false staleness")
        try expect(busy.snapshot.messages.count == 8, "initial excerpt is eight")
        try expect(collector.expand(busy, now: now).messages.count == 80, "one expansion is capped at 80")
        var expanded = busy; expanded.snapshot.contextPass = .expanded
        try rejects("second expansion") { _ = try collector.expand(expanded, now: now) }
        try db.execute("UPDATE message SET is_read=1")
        let changed = try collector.page(after: 0, now: now, timeZone: .current)
        try expect(changed.records.allSatisfy { $0.snapshot.messages.allSatisfy { $0.readState == .read } }, "read state changes without inserts")
        try expect(!collector.isCurrent(busy), "read change rejects old snapshot")
        try db.execute("ALTER TABLE message DROP COLUMN is_read")
        let unknown = try collector.page(after: 0, now: now, timeZone: .current)
        try expect(unknown.records.allSatisfy { $0.snapshot.messages.allSatisfy { $0.readState == .unknown } }, "missing column yields unknown")
        let facts = ManagedMessagesCollector.activityFacts(metadata: [(now,false,true),(now,true,false)], start: now.addingTimeInterval(-100), now: now, timeZone: .current)
        try expect(facts.first { $0.metric == "incoming7d" }?.value == "0", "reactions do not count as conversation activity")
        try expect(!facts.contains { $0.metric == "medianGapDays" }, "sparse history does not invent patterns")
        let imported = try MinderStore(databaseURL: root.appendingPathComponent("legacy.sqlite"))
        try imported.saveHistoryWindowDays(90)
        try expect(imported.managedState().historyWindowDays == 90, "history window is stored locally")
        try rejects("history window below range") { try imported.saveHistoryWindowDays(6) }
        try rejects("history window above range") { try imported.saveHistoryWindowDays(181) }
        let importer = AppleMessagesConversationImporter(databaseURL: url)
        _ = try await importer.importRecent(into: imported, since: now.addingTimeInterval(-86400))
        try db.execute("ALTER TABLE message ADD COLUMN is_read INTEGER DEFAULT 1")
        _ = try await importer.importRecent(into: imported, since: now.addingTimeInterval(-86400))
        try expect(imported.fetchMessages().allSatisfy { $0.readState == .read }, "legacy import updates mutable reads too")
        let legacyMessage = try imported.fetchMessages()[0]
        let draft = SuggestionDraft(type: .followUpNudge, title: "Existing reminder", actionText: "Reply", confidence: 0.9, sourceId: legacyMessage.sourceId, threadId: legacyMessage.threadId, messageId: legacyMessage.id, sourceApp: "Apple Messages", threadTitle: "Busy", evidenceSnippet: legacyMessage.body, sourceTimestamp: legacyMessage.sentAt)
        let saved = try imported.upsertSuggestions([draft])[0]
        try imported.updateManagedState { $0.mode = .managed; $0.accountId = "a"; $0.consentVersion = 1 }
        try imported.seedLegacyManagedQueue()
        try expect(imported.managedState().visible().count == 1 && imported.managedState().visible()[0].stale, "migration retains the old queue while awaiting managed analysis")
        try imported.managedAction(.done, recommendationId: "legacy-" + saved.id)
        try expect(imported.fetchSuggestions().first?.state == .completed, "Done on migrated items preserves compatibility history")
        try imported.saveUserProfile(UserProfile(displayName: "Existing owner"))
        let upgradeDB = try SQLiteDatabase(url: root.appendingPathComponent("legacy.sqlite"))
        for column in ["read_state","sender_id","event_kind","content_availability","truncated"] { try upgradeDB.execute("ALTER TABLE messages DROP COLUMN " + column) }
        try upgradeDB.execute("DROP TABLE managed_ai_state")
        let upgraded = try MinderStore(databaseURL: root.appendingPathComponent("legacy.sqlite"))
        try expect(upgraded.fetchSuggestions().first?.state == .completed, "upgrade preserves Done history")
        try expect(upgraded.fetchUserProfile()?.displayName == "Existing owner", "upgrade preserves user profile")
        try expect(upgraded.fetchMessages().count > 0 && upgraded.fetchMessages().allSatisfy { $0.readState == .unknown }, "upgrade preserves messages with unknown mutable metadata")

    }
    @MainActor static func staleChecks(root: URL, record: ManagedThreadRecord, content: RecommendationContent) async throws {
        for mutation in ["goal", "account", "consent", "snooze", "mute", "snapshot"] {
            let store = try MinderStore(databaseURL: root.appendingPathComponent("stale-" + mutation + ".sqlite"))
            var state = ManagedLocalState(); state.mode = .managed; state.accountId = "a"; state.consentVersion = 1; try store.saveManagedState(state)
            let collector = FakeCollector([record]); let service = FakeService(content)
            let coordinator = ManagedAssessmentCoordinator(store: store, service: service, collector: collector)
            try await coordinator.refresh(profile: UserProfile(displayName: "Kai"))
            let id = try store.managedState().visible()[0].id
            try store.saveGoal("Reassess")
            service.duringAssessment = {
                switch mutation {
                case "goal": try store.saveGoal("Changed while running")
                case "account": try store.updateManagedState { $0.accountId = "b"; $0.revision += 1 }
                case "consent": try store.updateManagedState { $0.consentVersion = 0; $0.revision += 1 }
                case "snooze": try store.managedAction(.snoozed, recommendationId: id)
                case "mute": try store.managedAction(.muted, recommendationId: id)
                default: try store.updateManagedState { $0.threads[record.snapshot.threadId]?.snapshot.snapshotId = "new-source-snapshot" }
                }
            }
            do { try await coordinator.refresh(profile: UserProfile(displayName: "Kai")); throw ManagedAIError.unavailable("Accepted stale " + mutation) }
            catch ManagedAIError.staleResult {}
            try expect(store.managedState().recommendations.count == 1, "stale " + mutation + " cannot create another recommendation")
        }
    }
    @MainActor static func expansionAndRankingChecks(root: URL, record: ManagedThreadRecord, content: RecommendationContent) async throws {
        let store = try MinderStore(databaseURL: root.appendingPathComponent("expansion.sqlite"))
        var state = ManagedLocalState(); state.accountId = "a"; state.mode = .managed; state.consentVersion = 1; try store.saveManagedState(state)
        var record = record; record.snapshot.coverage.moreContextAvailable = true
        let collector = FakeCollector([record]), service = FakeService(content); service.disposition = .needs_context
        let coordinator = ManagedAssessmentCoordinator(store: store, service: service, collector: collector)
        try await coordinator.refresh(profile: UserProfile(displayName: "Kai"))
        try expect(collector.expansions == 1 && service.assessmentCalls == 2, "at most one expansion")
        try expect(store.managedState().coverage.unresolved == 1 && store.managedState().visible().isEmpty, "expanded uncertainty remains unresolved")
        var records: [ManagedThreadRecord] = []
        for n in 0..<41 { var r = record; r.snapshot.threadId = "thread-\(n)"; r.snapshot.snapshotId = "snapshot-\(n)"; records.append(r) }
        collector.records = records; service.disposition = .recommend; try store.saveGoal("Follow through")
        try await coordinator.refresh(profile: UserProfile(displayName: "Kai"))
        try expect(store.managedState().visible().count == 41, "bounded ranking and merge never truncate the queue")
        try expect(Set(store.managedState().orderedIds).count == 41, "each ranked ID appears exactly once")
    }
}


private final class FakeSessionPersistence: ManagedSessionPersisting {
    var session: ManagedSession?
    var reads = 0
    var writes = 0
    var failLoad = false
    var failSave = false
    var failClear = false

    func load() throws -> ManagedSession? {
        reads += 1
        if failLoad { throw ManagedAIError.unavailable("Synthetic access denied") }
        return session
    }
    func save(_ value: ManagedSession) throws {
        writes += 1
        if failSave { throw ManagedAIError.unavailable("Synthetic write denied") }
        session = value
    }
    func clear() throws {
        if failClear { throw ManagedAIError.unavailable("Synthetic removal denied") }
        session = nil
    }
}

func sessionStoreChecks() throws {
    func session(_ account: String) -> ManagedSession {
        ManagedSession(access_token: "synthetic-access-" + account, refresh_token: "synthetic-refresh-" + account,
                       expires_at: Date().addingTimeInterval(3600).timeIntervalSince1970, user: .init(id: account))
    }
    let disk = FakeSessionPersistence()
    disk.session = session("owner")
    let store = ManagedSessionStore(persistence: disk)
    // Status, assessment batches, expansions, and ranking share one process cache.
    for _ in 0..<60 { try expect(store.load()?.user.id == "owner", "batch requests reuse the authorized session") }
    try expect(disk.reads == 1, "one Keychain read per running app, not per request")

    try store.save(session("replacement"))
    try expect(store.load()?.user.id == "replacement" && disk.reads == 1, "sign-in and token rotation replace cached credentials immediately")
    try store.clear()
    try expect(store.load() == nil && disk.session == nil && disk.reads == 1, "sign-out clears memory and persistent credentials")

    disk.failLoad = true
    let denied = ManagedSessionStore(persistence: disk)
    try rejects("Keychain denial") { _ = try denied.load() }
    disk.failLoad = false; disk.session = session("retry")
    try expect(denied.load()?.user.id == "retry", "a denied read is not cached as signed out")
    disk.failSave = true
    try rejects("failed credential write") { try denied.save(session("unpersisted")) }
    try expect(denied.load()?.user.id == "retry", "failed writes cannot install unpersisted credentials")
    disk.failSave = false; disk.failClear = true
    try rejects("failed credential removal") { try denied.clear() }
    disk.session = nil; disk.failClear = false
    try expect(denied.load() == nil, "failed removal invalidates cached credentials")

    let concurrentDisk = FakeSessionPersistence(); concurrentDisk.session = session("parallel")
    let concurrentStore = ManagedSessionStore(persistence: concurrentDisk)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in _ = try? concurrentStore.load() }
    try expect(concurrentDisk.reads == 1, "simultaneous clients cannot trigger duplicate Keychain reads")
    try expect(concurrentStore.load()?.user.id == "parallel", "concurrent access preserves session identity")
}
