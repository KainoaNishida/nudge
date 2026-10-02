import Foundation

public struct DailyActivity: Codable, Equatable {
    public var date: Date; public var incoming: Int; public var outgoing: Int
}
public struct ManagedScanPage {
    public var records: [ManagedThreadRecord]; public var nextCursor: Int; public var complete: Bool
}
public protocol ThreadContextCollecting {
    func page(after: Int, now: Date, timeZone: TimeZone) throws -> ManagedScanPage
    func expand(_ record: ManagedThreadRecord, now: Date) throws -> ThreadSnapshot
    func isCurrent(_ record: ManagedThreadRecord) throws -> Bool
}
public final class ManagedMessagesCollector: ThreadContextCollecting {
    private static let initialMessageLimit = 8
    private let databaseURL: URL
    private let contactResolver: ContactResolving
    private let historyWindowDays: Int
    public init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"), contactResolver: ContactResolving = NoOpContactResolver(), historyWindowDays: Int = ManagedLocalState.defaultHistoryWindowDays) {
        self.databaseURL = databaseURL; self.contactResolver = contactResolver
        self.historyWindowDays = min(ManagedLocalState.allowedHistoryWindowDays.upperBound, max(ManagedLocalState.allowedHistoryWindowDays.lowerBound, historyWindowDays))
    }
    public func page(after cursor: Int, now: Date, timeZone: TimeZone) throws -> ManagedScanPage {
        let validation = try AppleMessagesSchemaValidator.validate(databaseURL: databaseURL)
        guard validation.isCompatible else { throw AppleMessagesImportError.incompatibleSchema(validation.missingItems) }
        let db = try SQLiteReadOnlyDatabase(url: databaseURL)
        let cutoff = now.addingTimeInterval(-Double(historyWindowDays) * 86_400)
        let rows = try db.query("""
            SELECT chat.ROWID AS chat_id, chat.guid, chat.display_name FROM chat
            WHERE chat.ROWID > ? AND EXISTS (SELECT 1 FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id
            WHERE j.chat_id=chat.ROWID AND m.date >= ?) ORDER BY chat.ROWID LIMIT 32
            """, [.int(cursor), .double(Double(AppleMessagesDateCodec.messageDateValue(from: cutoff)))])
        var records: [ManagedThreadRecord] = []
        for row in rows {
            guard let chat = row["chat_id"] ?? nil, let chatID = Int(chat), let guid = row["guid"] ?? nil else { throw ManagedAIError.unavailable("Unsupported Messages conversation metadata; analysis remains incomplete.") }
            let cols = try db.tableColumns("message")
            let event = "(coalesce(" + (cols.contains("associated_message_type") ? "m.associated_message_type" : "0") + ",0) + coalesce(" + (cols.contains("item_type") ? "m.item_type" : "0") + ",0))"
            // Page metadata, never bodies, for the selected local history window.
            var metadata: [(Date, Bool, Bool)] = []; var messageCursor = 0
            while true {
                let page = try db.query("""
                    SELECT m.ROWID AS id,m.date,m.is_from_me,\(event) AS event FROM message m
                    JOIN chat_message_join j ON j.message_id=m.ROWID WHERE j.chat_id=? AND m.date>=? AND m.ROWID>?
                    ORDER BY m.ROWID LIMIT 1000
                    """, [.int(chatID), .double(Double(AppleMessagesDateCodec.messageDateValue(from: cutoff))), .int(messageCursor)])
                for message in page {
                    guard let date = Int64((message["date"] ?? nil) ?? ""), let id = Int((message["id"] ?? nil) ?? "") else { throw ManagedAIError.invalidResponse }
                    metadata.append((AppleMessagesDateCodec.date(fromMessageDateValue: date), (message["is_from_me"] ?? nil) == "1", ((message["event"] ?? nil) ?? "0") != "0")); messageCursor = id
                }
                if page.count < 1000 { break }
            }
            let first = try db.query("SELECT min(m.date) AS first FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID WHERE j.chat_id=? AND m.date>0", [.int(chatID)]).first
            let earliest = Int64((first?["first"] ?? nil) ?? "").map(AppleMessagesDateCodec.date(fromMessageDateValue:)) ?? cutoff
            let start = max(cutoff, earliest)
            let id = ManagedJSON.opaque("messages-thread:" + guid)
            let messages = try context(db: db, chatID: chatID, cutoff: cutoff, limit: Self.initialMessageLimit)
            let handles = try db.query("SELECT DISTINCT h.id FROM handle h JOIN message m ON m.handle_id=h.ROWID JOIN chat_message_join j ON j.message_id=m.ROWID WHERE j.chat_id=? AND m.date>=? ORDER BY h.id", [.int(chatID), .double(Double(AppleMessagesDateCodec.messageDateValue(from: cutoff)))])
            var participants = handles.enumerated().map { index, row -> Participant in
                let handle = (row["id"] ?? nil) ?? "unknown"
                let name = contactResolver.displayName(for: handle) ?? "Participant \(index + 1)"
                return Participant(id: ManagedJSON.opaque("sender:" + handle), displayName: name, isLocalUser: false)
            }
            participants.append(Participant(id: "local-user", displayName: "You", isLocalUser: true))
            Self.includeUnknownSenders(in: &participants, messages: messages)
            let rawTitle = (row["display_name"] ?? nil) ?? ""
            let title = !rawTitle.isEmpty && !ContactHandleNormalizer.looksLikeRawHandle(rawTitle) ? rawTitle : participants.filter { !$0.isLocalUser }.map(\.displayName).joined(separator: ", ")
            var snapshot = ThreadSnapshot(threadId: id, snapshotId: "", title: title.isEmpty ? "Conversation" : String(title.prefix(200)), kind: guid.contains(";+;") ? .group : (guid.contains(";-;") ? .direct : .unknown), participants: participants, messages: messages,
                activityFacts: Self.activityFacts(metadata: metadata, start: start, now: now, timeZone: timeZone, historyWindowDays: historyWindowDays),
                coverage: ContextCoverage(scanComplete: true, observationStart: start, observationEnd: now, excerptStart: messages.first?.sentAt, excerptEnd: messages.last?.sentAt, moreContextAvailable: metadata.count > messages.count), previousRecommendation: nil, feedback: [], contextPass: .initial)
            if let last = try context(db: db, chatID: chatID, cutoff: cutoff, limit: 1, substantiveOnly: true).first {
                snapshot.activityFacts.append(ActivityFact(id: "activity-substantive-revision", metric: "lastSubstantiveMessage", value: ManagedJSON.opaque(last.id + last.body), windowStart: start, windowEnd: now))
            }
            try snapshot.stamp()
            var record = ManagedThreadRecord(snapshot: snapshot, localThreadId: ImportIDs.stableID(prefix: "thread", sourceId: ImportIDs.sourceID(for: .appleMessages), externalId: guid), externalId: guid)
            record.localDisplayTitle = rawTitle.isEmpty ? handles.compactMap { row in (row["id"] ?? nil).map { contactResolver.displayName(for: $0) ?? $0 } }.joined(separator: ", ") : rawTitle
            for row in handles { if let handle = row["id"] ?? nil { record.localSenderLabels[ManagedJSON.opaque("sender:" + handle)] = contactResolver.displayName(for: handle) ?? handle } }
            record.localSenderLabels["local-user"] = "You"
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            record.dailyActivity = Dictionary(grouping: metadata.filter { !$0.2 }, by: { calendar.startOfDay(for: $0.0) }).map { day, rows in
                DailyActivity(date: day, incoming: rows.filter { !$0.1 }.count, outgoing: rows.filter { $0.1 }.count)
            }.sorted { $0.date < $1.date }
            records.append(record)
        }
        return ManagedScanPage(records: records, nextCursor: Int((rows.last?["chat_id"] ?? nil) ?? "") ?? cursor, complete: rows.count < 32)
    }
    public func isCurrent(_ record: ManagedThreadRecord) throws -> Bool {
        let db = try SQLiteReadOnlyDatabase(url: databaseURL)
        guard let row = try db.query("SELECT ROWID AS id FROM chat WHERE guid=?", [.text(record.externalId)]).first,
              let chatID = Int((row["id"] ?? nil) ?? "") else { return false }
        let current = try context(db: db, chatID: chatID, cutoff: record.snapshot.coverage.observationStart, limit: record.snapshot.messages.count)
        return try ManagedJSON.hash(current) == ManagedJSON.hash(record.snapshot.messages)
    }
    public func expand(_ record: ManagedThreadRecord, now: Date) throws -> ThreadSnapshot {
        guard record.snapshot.contextPass == .initial else { throw ManagedAIError.invalidResponse }
        let db = try SQLiteReadOnlyDatabase(url: databaseURL)
        guard let row = try db.query("SELECT ROWID AS id FROM chat WHERE guid=?", [.text(record.externalId)]).first, let chatID = Int((row["id"] ?? nil) ?? "") else { throw ManagedAIError.invalidResponse }
        let cutoff = record.snapshot.coverage.observationStart
        let latest = try context(db: db, chatID: chatID, cutoff: cutoff, limit: 80)
        // Preserve initial excerpt; reserve space for prior recommendation evidence and nearby replies.
        var selected = record.snapshot.messages
        let prior = record.snapshot.previousRecommendation?.content.evidenceRefs.filter { $0.kind == .message }.map(\.id) ?? []
        let pinned = prior.compactMap { id in record.stagedRecommendation?.evidenceMessages.first { $0.id == id && $0.sentAt >= cutoff } }
        for message in pinned where selected.count < 80 && !selected.contains(where: { $0.id == message.id }) { selected.append(message) }
        for local in pinned {
            let around = try context(db: db, chatID: chatID, cutoff: max(cutoff, local.sentAt.addingTimeInterval(-7 * 86_400)), limit: 20, end: local.sentAt.addingTimeInterval(7 * 86_400))
            for message in around where selected.count < 80 && !selected.contains(where: { $0.id == message.id }) { selected.append(message) }
        }
        for message in latest.reversed() where selected.count < 80 && !selected.contains(where: { $0.id == message.id }) { selected.append(message) }
        var result = record.snapshot; result.messages = selected.sorted { $0.sentAt < $1.sentAt }; result.contextPass = .expanded
        Self.includeUnknownSenders(in: &result.participants, messages: result.messages)
        result.coverage.excerptStart = result.messages.first?.sentAt; result.coverage.excerptEnd = result.messages.last?.sentAt
        // Keep snapshot revision: expansion is additional evidence for the same source snapshot.
        return result
    }
    private static func includeUnknownSenders(in participants: inout [Participant], messages: [ContextMessage]) {
        // System events can have no handle row. Preserve the event and its incomplete
        // content without inventing an identity or violating sender membership.
        var known = Set(participants.map(\.id))
        for message in messages where known.insert(message.senderId).inserted {
            participants.append(Participant(id: message.senderId, displayName: "Unknown participant", isLocalUser: false))
        }
    }
    private func context(db: SQLiteReadOnlyDatabase, chatID: Int, cutoff: Date, limit: Int, end: Date = .distantFuture, substantiveOnly: Bool = false) throws -> [ContextMessage] {
        let cols = try db.tableColumns("message")
        let read = cols.contains("is_read") ? "m.is_read" : "NULL"
        let event = cols.contains("associated_message_type") ? "m.associated_message_type" : "0"
        let attachment = cols.contains("cache_has_attachments") ? "m.cache_has_attachments" : "0"
        let attributed = cols.contains("attributedBody") ? "hex(m.attributedBody)" : "NULL"
        let payload = cols.contains("payload_data") ? "hex(m.payload_data)" : "NULL"
        let summary = cols.contains("message_summary_info") ? "hex(m.message_summary_info)" : "NULL"
        let item = cols.contains("item_type") ? "m.item_type" : "0"
        let rows = try db.query("""
            SELECT m.ROWID AS id,m.guid,m.date,m.text,m.is_from_me,h.id AS sender,\(read) AS read_state,\(event) AS event,
            \(attachment) AS attachment,\(attributed) AS attributed,\(payload) AS payload,\(summary) AS summary,\(item) AS item FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
            LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE j.chat_id=? AND m.date>=? AND m.date<=? \((substantiveOnly && cols.contains("associated_message_type")) ? "AND coalesce(m.associated_message_type,0)=0" : "") \((substantiveOnly && cols.contains("item_type")) ? "AND coalesce(m.item_type,0)=0" : "") ORDER BY m.date DESC,m.ROWID DESC LIMIT ?
            """, [.int(chatID), .double(Double(AppleMessagesDateCodec.messageDateValue(from: cutoff))), .double(end == .distantFuture ? Double(Int64.max) : Double(AppleMessagesDateCodec.messageDateValue(from: end))), .int(limit)])
        return try rows.reversed().map { row in
            guard let date = Int64((row["date"] ?? nil) ?? "") else { throw ManagedAIError.invalidResponse }
            let outgoing = (row["is_from_me"] ?? nil) == "1"
            let plain = row["text"] ?? nil
            let decoded = plain.flatMap { $0.isEmpty ? nil : $0 } ?? AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["attributed"] ?? nil)
                ?? AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["payload"] ?? nil)
                ?? AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["summary"] ?? nil)
            let body = decoded ?? ""
            let sender = (row["sender"] ?? nil) ?? "unknown"
            let rawRead = row["read_state"] ?? nil
            return ContextMessage(id: ManagedJSON.opaque("message:" + ((row["guid"] ?? nil) ?? (row["id"] ?? nil) ?? "")), senderId: outgoing ? "local-user" : ManagedJSON.opaque("sender:" + sender), sentAt: AppleMessagesDateCodec.date(fromMessageDateValue: date), isFromUser: outgoing, body: ManagedJSON.boundedBody(body), readState: outgoing ? .unknown : (rawRead == "1" ? .read : (rawRead == "0" ? .unread : .unknown)), eventKind: ((row["item"] ?? nil) ?? "0") != "0" ? .system : (((row["event"] ?? nil) ?? "0") != "0" ? .reaction : .message), contentAvailability: decoded != nil ? .available : ((row["attachment"] ?? nil) == "1" ? .attachmentOnly : .unavailable), truncated: body.utf8.count > 2_000)
        }
    }
    static func activityFacts(metadata: [(Date, Bool, Bool)], start: Date, now: Date, timeZone: TimeZone, historyWindowDays: Int = ManagedLocalState.defaultHistoryWindowDays) -> [ActivityFact] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let substantive = metadata.filter { !$0.2 && $0.0 <= now }
        var facts: [ActivityFact] = []
        func add(_ metric: String, _ value: String, _ from: Date) { facts.append(ActivityFact(id: "activity-" + metric, metric: metric, value: value, windowStart: from, windowEnd: now)) }
        for (name, items) in [("lastIncoming", substantive.filter { !$0.1 }), ("lastOutgoing", substantive.filter { $0.1 }), ("lastActivity", substantive)] {
            if let date = items.map({ $0.0 }).max() { add(name, ISO8601DateFormatter().string(from: date), start) }
        }
        for days in [7,30].filter({ $0 <= historyWindowDays }) {
            let from = max(start, calendar.date(byAdding: .day, value: -days, to: now)!)
            let items = substantive.filter { $0.0 >= from }
            add("incoming\(days)d", String(items.filter { !$0.1 }.count), from)
            add("outgoing\(days)d", String(items.filter { $0.1 }.count), from)
            add("activeDays\(days)d", String(Set(items.map { calendar.startOfDay(for: $0.0) }).count), from)
        }
        add("incomingWindow", String(substantive.filter { !$0.1 }.count), start)
        add("outgoingWindow", String(substantive.filter { $0.1 }.count), start)
        add("activeDaysWindow", String(Set(substantive.map { calendar.startOfDay(for: $0.0) }).count), start)
        for week in 0..<((historyWindowDays + 6) / 7) {
            let end = calendar.date(byAdding: .day, value: -7 * week, to: now)!
            let from = max(start, calendar.date(byAdding: .day, value: -7, to: end)!)
            if from >= end { continue }
            let items = substantive.filter { $0.0 >= from && $0.0 < end }
            facts.append(ActivityFact(id: "activity-week-\(week)", metric: "week\(week)", value: "\(items.filter { !$0.1 }.count) incoming, \(items.filter { $0.1 }.count) outgoing, \(Set(items.map { calendar.startOfDay(for: $0.0) }).count) active days", windowStart: from, windowEnd: end))
        }
        let days = Set(substantive.map { calendar.startOfDay(for: $0.0) }).sorted()
        if days.count >= 4 {
            let gaps = zip(days, days.dropFirst()).map { calendar.dateComponents([.day], from: $0, to: $1).day ?? 0 }.sorted()
            let mid = gaps.count / 2; let median = gaps.count % 2 == 0 ? Double(gaps[mid-1] + gaps[mid]) / 2 : Double(gaps[mid])
            add("medianGapDays", String(median), start)
        }
        return facts
    }
}
