import Foundation

public enum MinderStoreError: Error, LocalizedError {
    case missingColumn(String)
    case invalidStoredValue(String)

    public var errorDescription: String? {
        switch self {
        case .missingColumn(let column): return "Missing database column: \(column)"
        case .invalidStoredValue(let value): return "Invalid stored value: \(value)"
        }
    }
}

public final class MinderStore {
    let database: SQLiteDatabase

    public init(databaseURL: URL = MinderStore.defaultDatabaseURL()) throws {
        if databaseURL == MinderStore.defaultDatabaseURL() {
            try MinderStore.migrateLegacyDefaultDatabaseIfNeeded(to: databaseURL)
        }
        database = try SQLiteDatabase(url: databaseURL)
        try migrate()
        try migrateManagedAI()
    }

    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let channel = NudgeReleaseChannel.current()
        return appSupport
            .appendingPathComponent(channel.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("nudge.sqlite")
    }

    private static func legacyDefaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("MinderDev", isDirectory: true)
            .appendingPathComponent("minder.sqlite")
    }

    private static func legacyLoopDefaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let channel = NudgeReleaseChannel.current()
        return appSupport
            .appendingPathComponent(channel.legacyLoopAppSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("loop.sqlite")
    }

    private static func migrateLegacyDefaultDatabaseIfNeeded(to databaseURL: URL) throws {
        let fileManager = FileManager.default
        let legacyURL = legacyLoopDefaultDatabaseURL()
        let olderLegacyURL = legacyDefaultDatabaseURL()
        let sourceURL = fileManager.fileExists(atPath: legacyURL.path) ? legacyURL : olderLegacyURL
        guard
            !fileManager.fileExists(atPath: databaseURL.path),
            fileManager.fileExists(atPath: sourceURL.path)
        else {
            return
        }

        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: databaseURL)

        for suffix in ["-shm", "-wal"] {
            let legacySidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            let newSidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: legacySidecar.path), !fileManager.fileExists(atPath: newSidecar.path) {
                try fileManager.copyItem(at: legacySidecar, to: newSidecar)
            }
        }
    }

    public func eraseAllData() throws {
        try clearManagedData(keepPreferences: false)
        try database.transaction {
#if NUDGE_INTERNAL_DIAGNOSTICS
            try database.execute("DELETE FROM gemini_diagnostic_runs")
#endif
            try database.execute("DELETE FROM audit_events")
            try database.execute("DELETE FROM suggestions")
            try database.execute("DELETE FROM manual_queue_items")
            try database.execute("DELETE FROM messages")
            try database.execute("DELETE FROM threads")
            try database.execute("DELETE FROM sources")
            try database.execute("DELETE FROM permission_health")
            try database.execute("DELETE FROM user_profiles")
        }
    }

    public func deleteSuggestions() throws {
        try clearManagedData(keepPreferences: true)
        try database.transaction {
            try database.execute("DELETE FROM suggestions")
            try insertAuditEvent(AuditEvent(
                eventType: "suggestions_deleted",
                details: "Deleted all generated suggestions."
            ))
        }
    }

    public func deleteImportedConversationCache() throws {
        try clearManagedData(keepPreferences: true)
        try database.transaction {
            try database.execute("DELETE FROM suggestions")
            try database.execute("DELETE FROM messages")
            try database.execute("DELETE FROM threads")
            try database.execute("DELETE FROM sources")
            try insertAuditEvent(AuditEvent(
                eventType: "conversation_cache_deleted",
                details: "Deleted imported sources, threads, messages, and suggestions."
            ))
        }
    }

    public func fetchUserProfile() throws -> UserProfile? {
        try database.query("SELECT * FROM user_profiles WHERE id = ?", [.text(UserProfile.defaultID)])
            .first
            .map(userProfile(from:))
    }

    public func saveUserProfile(_ profile: UserProfile) throws {
        let existing = try fetchUserProfile()
        let createdAt = existing?.createdAt ?? profile.createdAt
        let saved = UserProfile(
            id: profile.id,
            displayName: profile.displayName,
            timeZoneIdentifier: profile.timeZoneIdentifier,
            notificationCadence: profile.notificationCadence,
            quietHoursStartMinutes: profile.quietHoursStartMinutes,
            quietHoursEndMinutes: profile.quietHoursEndMinutes,
            sourcePriority: profile.sourcePriority,
            cloudAIEnabled: profile.cloudAIEnabled,
            appColorScheme: profile.appColorScheme,
            completedOnboardingAt: profile.completedOnboardingAt,
            createdAt: createdAt,
            updatedAt: Date()
        )

        try database.transaction {
            try database.execute(
                """
                INSERT INTO user_profiles (
                    id, display_name, time_zone_identifier, notification_cadence,
                    quiet_hours_start_minutes, quiet_hours_end_minutes, source_priority,
                    cloud_ai_enabled, app_color_scheme, completed_onboarding_at, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    time_zone_identifier = excluded.time_zone_identifier,
                    notification_cadence = excluded.notification_cadence,
                    quiet_hours_start_minutes = excluded.quiet_hours_start_minutes,
                    quiet_hours_end_minutes = excluded.quiet_hours_end_minutes,
                    source_priority = excluded.source_priority,
                    cloud_ai_enabled = excluded.cloud_ai_enabled,
                    app_color_scheme = excluded.app_color_scheme,
                    completed_onboarding_at = excluded.completed_onboarding_at,
                    updated_at = excluded.updated_at
                """,
                [
                    .text(saved.id),
                    .text(saved.displayName),
                    .text(saved.timeZoneIdentifier),
                    .text(saved.notificationCadence.rawValue),
                    .int(saved.quietHoursStartMinutes),
                    .int(saved.quietHoursEndMinutes),
                    .text(encodeSourceKindArray(saved.sourcePriority)),
                    .int(saved.cloudAIEnabled ? 1 : 0),
                    .text(saved.appColorScheme.rawValue),
                    optionalDate(saved.completedOnboardingAt),
                    requiredDate(saved.createdAt),
                    requiredDate(saved.updatedAt)
                ]
            )
            try insertAuditEvent(AuditEvent(
                eventType: saved.hasCompletedOnboarding ? "profile_completed" : "profile_saved",
                entityId: saved.id,
                details: saved.hasCompletedOnboarding ? "Onboarding profile completed." : "Onboarding profile saved."
            ))
        }
    }

    public func hasCompletedOnboarding() throws -> Bool {
        try fetchUserProfile()?.hasCompletedOnboarding ?? false
    }

    public func fetchPermissionHealth() throws -> [PermissionHealth] {
        try database.query("SELECT * FROM permission_health ORDER BY kind").map(permissionHealth(from:))
    }

    public func fetchPermissionHealth(kind: PermissionKind) throws -> PermissionHealth? {
        try database.query("SELECT * FROM permission_health WHERE kind = ?", [.text(kind.rawValue)])
            .first
            .map(permissionHealth(from:))
    }

    public func upsertPermissionHealth(_ health: PermissionHealth) throws {
        try upsertPermissionHealth([health])
    }

    public func upsertPermissionHealth(_ healthItems: [PermissionHealth]) throws {
        try database.transaction {
            for health in healthItems {
                try database.execute(
                    """
                    INSERT INTO permission_health (kind, state, detail, last_checked_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(kind) DO UPDATE SET
                        state = excluded.state,
                        detail = excluded.detail,
                        last_checked_at = excluded.last_checked_at
                    """,
                    [
                        .text(health.kind.rawValue),
                        .text(health.state.rawValue),
                        .text(health.detail),
                        requiredDate(health.lastCheckedAt)
                    ]
                )
            }

            if !healthItems.isEmpty {
                try insertAuditEvent(AuditEvent(
                    eventType: "permission_health_refreshed",
                    details: "Updated \(healthItems.count) permission health states."
                ))
            }
        }
    }

    public func saveImport(source: ConversationSource, threads: [ConversationThread], messages: [Message]) throws -> ImportResult {
        try database.transaction {
            let sourceExists = try exists("SELECT id FROM sources WHERE id = ?", [.text(source.id)])
            try database.execute(
                """
                INSERT INTO sources (id, name, kind, health, last_sync_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    kind = excluded.kind,
                    health = excluded.health,
                    last_sync_at = excluded.last_sync_at
                """,
                [
                    .text(source.id),
                    .text(source.name),
                    .text(source.kind.rawValue),
                    .text(source.health.rawValue),
                    optionalDate(source.lastSyncAt)
                ]
            )

            var insertedThreads = 0
            for thread in threads {
                let threadExists = try exists("SELECT id FROM threads WHERE id = ?", [.text(thread.id)])
                if !threadExists { insertedThreads += 1 }
                let savedThread = try bestThreadForSave(thread)
                try database.execute(
                    """
                    INSERT INTO threads (id, source_id, external_id, title, participant_labels, last_message_at, is_active)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        participant_labels = excluded.participant_labels,
                        last_message_at = excluded.last_message_at,
                        is_active = excluded.is_active
                    """,
                    [
                        .text(savedThread.id),
                        .text(savedThread.sourceId),
                        .text(savedThread.externalId),
                        .text(savedThread.title),
                        .text(encodeStringArray(savedThread.participantLabels)),
                        requiredDate(savedThread.lastMessageAt),
                        .int(savedThread.isActive ? 1 : 0)
                    ]
                )
            }

            var insertedMessages = 0
            var skippedMessages = 0
            for message in messages {
                let messageExists = try exists("SELECT id FROM messages WHERE id = ?", [.text(message.id)])
                if messageExists {
                    skippedMessages += 1
                    try updateMessageLabelIfBetter(message)
                    try updateMessageBodyIfBetter(message)
                } else {
                    insertedMessages += 1
                    try database.execute(
                        """
                        INSERT INTO messages (id, source_id, thread_id, external_id, sender_label, sent_at, body, is_from_user)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(message.id),
                            .text(message.sourceId),
                            .text(message.threadId),
                            .text(message.externalId),
                            .text(message.senderLabel),
                            requiredDate(message.sentAt),
                            .text(message.body),
                            .int(message.isFromUser ? 1 : 0)
                        ]
                    )
                }
            }

            // Read state is mutable even when every imported message was already present.
            for message in messages {
                try database.execute("UPDATE messages SET read_state=?,sender_id=?,event_kind=?,content_availability=?,truncated=? WHERE id=?", [.text(message.readState.rawValue),.text(message.senderId),.text(message.eventKind.rawValue),.text(message.contentAvailability.rawValue),.int(message.truncated ? 1 : 0),.text(message.id)])
            }

            try insertAuditEvent(AuditEvent(
                eventType: "sample_import",
                entityId: source.id,
                details: "Imported \(insertedMessages) messages; skipped \(skippedMessages) duplicates."
            ))

            return ImportResult(
                insertedSources: sourceExists ? 0 : 1,
                insertedThreads: insertedThreads,
                insertedMessages: insertedMessages,
                skippedMessages: skippedMessages
            )
        }
    }

    public func fetchSources() throws -> [ConversationSource] {
        try database.query("SELECT * FROM sources ORDER BY name").map(source(from:))
    }

    public func fetchThreads() throws -> [ConversationThread] {
        try database.query("SELECT * FROM threads ORDER BY last_message_at DESC").map(thread(from:))
    }

    public func fetchMessages(limit: Int = 200) throws -> [Message] {
        try database.query(
            "SELECT * FROM messages ORDER BY sent_at DESC LIMIT ?",
            [.int(limit)]
        )
        .map(message(from:))
        .sorted { $0.sentAt < $1.sentAt }
    }

    public func fetchRecentMessages(threadId: String, limit: Int = 4) throws -> [Message] {
        try database.query(
            "SELECT * FROM messages WHERE thread_id = ? ORDER BY sent_at DESC LIMIT ?",
            [.text(threadId), .int(limit)]
        )
        .map(message(from:))
        .sorted { $0.sentAt < $1.sentAt }
    }

    public func fetchSuggestions(includeCompleted: Bool = true) throws -> [Suggestion] {
        let sql: String
        if includeCompleted {
            sql = "SELECT * FROM suggestions ORDER BY updated_at DESC"
            return try database.query(sql).map(suggestion(from:))
        } else {
            sql = "SELECT * FROM suggestions WHERE state NOT IN ('completed', 'dismissed', 'superseded') ORDER BY updated_at DESC"
            return try database.query(sql).map(suggestion(from:))
        }
    }

    public func upsertSuggestions(_ drafts: [SuggestionDraft]) throws -> [Suggestion] {
        try saveSuggestions(drafts, supersedeMissingActiveThreads: false)
    }

    public func replaceActiveSuggestions(with drafts: [SuggestionDraft]) throws -> [Suggestion] {
        try saveSuggestions(drafts, supersedeMissingActiveThreads: true)
    }

    private func saveSuggestions(_ drafts: [SuggestionDraft], supersedeMissingActiveThreads: Bool) throws -> [Suggestion] {
        let now = Date()
        return try database.transaction {
            var saved: [Suggestion] = []
            var currentThreadIds = Set<String>()
            for draft in drafts where draft.confidence >= 0.15 {
                currentThreadIds.insert(draft.threadId)
                let currentId = suggestionID(for: draft)
                let existingMatch = try existingSuggestionRow(for: draft, currentId: currentId)
                let id = existingMatch?.id ?? currentId
                let existing = existingMatch?.row
                let createdAt = existing.flatMap { DateCoding.date(from: $0["created_at"] ?? nil) } ?? now
                let state = existing.flatMap { row -> SuggestionState? in
                    guard let raw = row["state"] ?? nil else { return nil }
                    return SuggestionState(rawValue: raw)
                } ?? .new
                let completedAt = existing.flatMap { DateCoding.date(from: $0["completed_at"] ?? nil) }

                let suggestion = Suggestion(
                    id: id,
                    type: draft.type,
                    state: state,
                    title: draft.title,
                    action: SuggestionAction(text: draft.actionText, dueDate: draft.dueDate),
                    sourceId: draft.sourceId,
                    threadId: draft.threadId,
                    confidence: min(max(draft.confidence, 0), 1),
                    evidence: Evidence(
                        sourceApp: draft.sourceApp,
                        threadTitle: draft.threadTitle,
                        messageId: draft.messageId,
                        snippet: draft.evidenceSnippet,
                        sourceTimestamp: draft.sourceTimestamp
                    ),
                    createdAt: createdAt,
                    updatedAt: now,
                    snoozedUntil: existing.flatMap { DateCoding.date(from: $0["snoozed_until"] ?? nil) },
                    completedAt: completedAt
                )

                try database.execute(
                    """
                    INSERT INTO suggestions (
                        id, type, state, title, action_text, due_date, source_id, thread_id,
                        message_id, source_app, thread_title, evidence_snippet, source_timestamp,
                        confidence, created_at, updated_at, snoozed_until, completed_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        type = excluded.type,
                        title = excluded.title,
                        action_text = excluded.action_text,
                        due_date = excluded.due_date,
                        source_id = excluded.source_id,
                        thread_id = excluded.thread_id,
                        message_id = excluded.message_id,
                        source_app = excluded.source_app,
                        thread_title = excluded.thread_title,
                        evidence_snippet = excluded.evidence_snippet,
                        source_timestamp = excluded.source_timestamp,
                        confidence = excluded.confidence,
                        updated_at = excluded.updated_at
                    """,
                    [
                        .text(suggestion.id),
                        .text(suggestion.type.rawValue),
                        .text(suggestion.state.rawValue),
                        .text(suggestion.title),
                        .text(suggestion.action.text),
                        optionalDate(suggestion.action.dueDate),
                        .text(suggestion.sourceId),
                        .text(suggestion.threadId),
                        .text(suggestion.evidence.messageId),
                        .text(suggestion.evidence.sourceApp),
                        .text(suggestion.evidence.threadTitle),
                        .text(suggestion.evidence.snippet),
                        requiredDate(suggestion.evidence.sourceTimestamp),
                        .double(suggestion.confidence),
                        requiredDate(suggestion.createdAt),
                        requiredDate(suggestion.updatedAt),
                        optionalDate(suggestion.snoozedUntil),
                        optionalDate(suggestion.completedAt)
                    ]
                )
                if suggestion.state.isQueueActive {
                    try supersedeOlderActiveSuggestions(threadId: draft.threadId, keeping: suggestion.id, updatedAt: now)
                }
                saved.append(suggestion)
            }

            if supersedeMissingActiveThreads {
                try supersedeActiveSuggestionsNotIn(threadIds: currentThreadIds, updatedAt: now)
            }

            if !saved.isEmpty {
                try insertAuditEvent(AuditEvent(
                    eventType: "suggestions_generated",
                    details: "Generated or updated \(saved.count) suggestions."
                ))
            }
            return saved
        }
    }

    public func updateSuggestionState(id: String, state: SuggestionState, snoozedUntil: Date? = nil) throws {
        let now = Date()
        try database.transaction {
            try database.execute(
                "UPDATE suggestions SET state = ?, updated_at = ?, snoozed_until = ?, completed_at = ? WHERE id = ?",
                [
                    .text(state.rawValue),
                    requiredDate(now),
                    optionalDate(snoozedUntil),
                    optionalDate(state == .completed ? now : nil),
                    .text(id)
                ]
            )
            try insertAuditEvent(AuditEvent(
                eventType: "suggestion_state_changed",
                entityId: id,
                details: "State changed to \(state.rawValue)."
            ))
        }
    }

    @discardableResult
    public func createManualQueueItem(kind: ManualQueueItemKind, title: String, body: String? = nil) throws -> ManualQueueItem {
        guard let normalizedTitle = title.collapsedWhitespace.nilIfEmpty else {
            throw MinderStoreError.invalidStoredValue("Manual queue item title is empty")
        }
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let now = Date()
        let item = ManualQueueItem(
            kind: kind,
            title: normalizedTitle,
            body: normalizedBody,
            createdAt: now,
            updatedAt: now
        )
        try upsertManualQueueItem(item)
        return item
    }

    public func fetchManualQueueItems(includeCompleted: Bool = true) throws -> [ManualQueueItem] {
        let sql = includeCompleted
            ? "SELECT * FROM manual_queue_items ORDER BY updated_at DESC"
            : "SELECT * FROM manual_queue_items WHERE state != 'completed' ORDER BY updated_at DESC"
        return try database.query(sql).map(manualQueueItem(from:))
    }

    public func upsertManualQueueItem(_ item: ManualQueueItem) throws {
        guard !item.title.collapsedWhitespace.isEmpty else {
            throw MinderStoreError.invalidStoredValue("Manual queue item title is empty")
        }
        try database.transaction {
            try database.execute(
                """
                INSERT INTO manual_queue_items (
                    id, kind, title, body, state, created_at, updated_at, completed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind,
                    title = excluded.title,
                    body = excluded.body,
                    state = excluded.state,
                    updated_at = excluded.updated_at,
                    completed_at = excluded.completed_at
                """,
                [
                    .text(item.id),
                    .text(item.kind.rawValue),
                    .text(item.title.collapsedWhitespace),
                    item.body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map(SQLiteValue.text) ?? .null,
                    .text(item.state.rawValue),
                    requiredDate(item.createdAt),
                    requiredDate(item.updatedAt),
                    optionalDate(item.completedAt)
                ]
            )
            try insertAuditEvent(AuditEvent(
                eventType: "manual_queue_item_saved",
                entityId: item.id,
                details: "Saved manual \(item.kind.rawValue)."
            ))
        }
    }

    public func updateManualQueueItemState(id: String, state: ManualQueueItemState) throws {
        let now = Date()
        try database.transaction {
            try database.execute(
                "UPDATE manual_queue_items SET state = ?, updated_at = ?, completed_at = ? WHERE id = ?",
                [
                    .text(state.rawValue),
                    requiredDate(now),
                    optionalDate(state == .completed ? now : nil),
                    .text(id)
                ]
            )
            try insertAuditEvent(AuditEvent(
                eventType: "manual_queue_item_state_changed",
                entityId: id,
                details: "Manual queue item changed to \(state.rawValue)."
            ))
        }
    }

    public func deleteManualQueueItem(id: String) throws {
        try database.transaction {
            try database.execute("DELETE FROM manual_queue_items WHERE id = ?", [.text(id)])
            try insertAuditEvent(AuditEvent(
                eventType: "manual_queue_item_deleted",
                entityId: id,
                details: "Deleted manual queue item."
            ))
        }
    }

    public func fetchAuditEvents(limit: Int = 100) throws -> [AuditEvent] {
        try database.query("SELECT * FROM audit_events ORDER BY created_at DESC LIMIT ?", [.int(limit)])
            .map(auditEvent(from:))
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    public func saveGeminiDiagnosticRun(_ run: GeminiDiagnosticRun) throws {
        try database.execute(
            """
            INSERT INTO gemini_diagnostic_runs (
                id, model, created_at, duration_ms, outcome, error_category,
                fallback_used, http_status, candidate_count, decision_count,
                ranked_count, saved_count, candidate_thread_ids,
                candidate_message_ids, detail
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(run.id),
                .text(run.model),
                requiredDate(run.createdAt),
                .int(run.durationMilliseconds),
                .text(run.outcome.rawValue),
                .text(run.errorCategory.rawValue),
                .int(run.fallbackUsed ? 1 : 0),
                run.httpStatus.map { .int($0) } ?? .null,
                .int(run.candidateCount),
                .int(run.decisionCount),
                .int(run.rankedCount),
                .int(run.savedCount),
                .text(encodeStringArray(run.candidateThreadIds)),
                .text(encodeStringArray(run.candidateMessageIds)),
                .text(run.detail)
            ]
        )
    }

    public func fetchGeminiDiagnosticRuns(limit: Int = 25) throws -> [GeminiDiagnosticRun] {
        try database.query(
            "SELECT * FROM gemini_diagnostic_runs ORDER BY created_at DESC LIMIT ?",
            [.int(limit)]
        )
        .map(geminiDiagnosticRun(from:))
    }

    public func clearGeminiDiagnosticRuns() throws {
        try database.execute("DELETE FROM gemini_diagnostic_runs")
    }
#endif

    private func migrate() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                health TEXT NOT NULL,
                last_sync_at TEXT
            )
            """
        )

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS threads (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                external_id TEXT NOT NULL,
                title TEXT NOT NULL,
                participant_labels TEXT NOT NULL,
                last_message_at TEXT NOT NULL,
                is_active INTEGER NOT NULL
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                external_id TEXT NOT NULL,
                sender_label TEXT NOT NULL,
                sent_at TEXT NOT NULL,
                body TEXT NOT NULL,
                is_from_user INTEGER NOT NULL
            )
            """
        )

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS suggestions (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                state TEXT NOT NULL,
                title TEXT NOT NULL,
                action_text TEXT NOT NULL,
                due_date TEXT,
                source_id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                source_app TEXT NOT NULL,
                thread_title TEXT NOT NULL,
                evidence_snippet TEXT NOT NULL,
                source_timestamp TEXT NOT NULL,
                confidence REAL NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                snoozed_until TEXT,
                completed_at TEXT
            )
            """
        )
        try ensureSuggestionSchema()
        try cleanupSuggestionData()

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS manual_queue_items (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT,
                state TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                completed_at TEXT
            )
            """
        )
        try ensureManualQueueItemSchema()
        try cleanupManualQueueItemData()

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS audit_events (
                id TEXT PRIMARY KEY,
                event_type TEXT NOT NULL,
                entity_id TEXT,
                details TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )

#if NUDGE_INTERNAL_DIAGNOSTICS
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS gemini_diagnostic_runs (
                id TEXT PRIMARY KEY,
                model TEXT NOT NULL,
                created_at TEXT NOT NULL,
                duration_ms INTEGER NOT NULL,
                outcome TEXT NOT NULL,
                error_category TEXT NOT NULL,
                fallback_used INTEGER NOT NULL,
                http_status INTEGER,
                candidate_count INTEGER NOT NULL,
                decision_count INTEGER NOT NULL,
                ranked_count INTEGER NOT NULL,
                saved_count INTEGER NOT NULL,
                candidate_thread_ids TEXT NOT NULL,
                candidate_message_ids TEXT NOT NULL,
                detail TEXT NOT NULL
            )
            """
        )
#endif

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS user_profiles (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                time_zone_identifier TEXT NOT NULL,
                notification_cadence TEXT NOT NULL,
                quiet_hours_start_minutes INTEGER NOT NULL,
                quiet_hours_end_minutes INTEGER NOT NULL,
                source_priority TEXT NOT NULL,
                cloud_ai_enabled INTEGER NOT NULL,
                app_color_scheme TEXT NOT NULL DEFAULT 'ocean',
                completed_onboarding_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        try ensureUserProfileSchema()

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS permission_health (
                kind TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                detail TEXT NOT NULL,
                last_checked_at TEXT NOT NULL
            )
            """
        )

        var messageColumns = try tableColumns("messages")
        for (column, definition) in [("read_state", "TEXT NOT NULL DEFAULT 'unknown'"), ("sender_id", "TEXT NOT NULL DEFAULT 'unknown'"), ("event_kind", "TEXT NOT NULL DEFAULT 'unknown'"), ("content_availability", "TEXT NOT NULL DEFAULT 'available'"), ("truncated", "INTEGER NOT NULL DEFAULT 0")] {
            try addColumnIfMissing(table: "messages", column: column, definition: definition, existingColumns: &messageColumns)
        }
        try cleanupLegacyGmailData()
    }

    private func ensureUserProfileSchema() throws {
        var columns = try tableColumns("user_profiles")
        try addColumnIfMissing(
            table: "user_profiles",
            column: "app_color_scheme",
            definition: "TEXT NOT NULL DEFAULT 'ocean'",
            existingColumns: &columns
        )
    }

    private func ensureSuggestionSchema() throws {
        var columns = try tableColumns("suggestions")
        try addColumnIfMissing(
            table: "suggestions",
            column: "completed_at",
            definition: "TEXT",
            existingColumns: &columns
        )
    }

    private func cleanupSuggestionData() throws {
        try database.transaction {
            try database.execute("UPDATE suggestions SET completed_at = updated_at WHERE state = 'completed' AND completed_at IS NULL")
            try database.execute("UPDATE suggestions SET completed_at = NULL WHERE state != 'completed'")

            let rows = try database.query("SELECT id, completed_at FROM suggestions WHERE completed_at IS NOT NULL")
            for row in rows {
                guard let id = row["id"] ?? nil else { continue }
                let completedAt = row["completed_at"] ?? nil
                if DateCoding.date(from: completedAt) == nil {
                    try database.execute("UPDATE suggestions SET completed_at = NULL WHERE id = ?", [.text(id)])
                }
            }
        }
    }

    private func ensureManualQueueItemSchema() throws {
        var columns = try tableColumns("manual_queue_items")
        try addColumnIfMissing(
            table: "manual_queue_items",
            column: "kind",
            definition: "TEXT NOT NULL DEFAULT 'todo'",
            existingColumns: &columns
        )
        try addColumnIfMissing(
            table: "manual_queue_items",
            column: "title",
            definition: "TEXT NOT NULL DEFAULT 'Untitled item'",
            existingColumns: &columns
        )
        try addColumnIfMissing(
            table: "manual_queue_items",
            column: "body",
            definition: "TEXT",
            existingColumns: &columns
        )
        try addColumnIfMissing(
            table: "manual_queue_items",
            column: "state",
            definition: "TEXT NOT NULL DEFAULT 'active'",
            existingColumns: &columns
        )
        try addColumnIfMissing(
            table: "manual_queue_items",
            column: "created_at",
            definition: "TEXT NOT NULL DEFAULT '1970-01-01T00:00:00.000Z'",
            existingColumns: &columns
        )
        try addColumnIfMissing(
            table: "manual_queue_items",
            column: "updated_at",
            definition: "TEXT NOT NULL DEFAULT '1970-01-01T00:00:00.000Z'",
            existingColumns: &columns
        )
        try addColumnIfMissing(
            table: "manual_queue_items",
            column: "completed_at",
            definition: "TEXT",
            existingColumns: &columns
        )
    }

    private func cleanupManualQueueItemData() throws {
        let now = DateCoding.iso8601.string(from: Date())
        try database.transaction {
            try database.execute("UPDATE manual_queue_items SET kind = 'todo' WHERE kind IN ('To-do', 'Todo', 'todo', 'task', 'Task')")
            try database.execute("UPDATE manual_queue_items SET kind = 'note' WHERE kind IN ('Note', 'Notes', 'note', 'notes')")
            try database.execute("DELETE FROM manual_queue_items WHERE id IS NULL OR TRIM(id) = ''")
            try database.execute("DELETE FROM manual_queue_items WHERE kind NOT IN ('todo', 'note')")
            try database.execute(
                """
                UPDATE manual_queue_items
                SET title = CASE WHEN kind = 'todo' THEN 'Untitled to-do' ELSE 'Untitled note' END
                WHERE title IS NULL OR TRIM(title) = ''
                """
            )
            try database.execute("UPDATE manual_queue_items SET state = 'completed' WHERE state IN ('Completed', 'done', 'Done')")
            try database.execute("UPDATE manual_queue_items SET state = 'active' WHERE state IS NULL OR TRIM(state) = '' OR state NOT IN ('active', 'completed')")
            try database.execute("UPDATE manual_queue_items SET created_at = ? WHERE created_at IS NULL OR TRIM(created_at) = ''", [.text(now)])
            try database.execute("UPDATE manual_queue_items SET updated_at = created_at WHERE updated_at IS NULL OR TRIM(updated_at) = ''")
            try database.execute("UPDATE manual_queue_items SET completed_at = NULL WHERE state != 'completed'")

            let rows = try database.query("SELECT id, created_at, updated_at, completed_at FROM manual_queue_items")
            for row in rows {
                guard let id = row["id"] ?? nil else { continue }
                let createdAt = row["created_at"] ?? nil
                let updatedAt = row["updated_at"] ?? nil
                let completedAt = row["completed_at"] ?? nil
                if DateCoding.date(from: createdAt) == nil {
                    try database.execute("UPDATE manual_queue_items SET created_at = ? WHERE id = ?", [.text(now), .text(id)])
                }
                if DateCoding.date(from: updatedAt) == nil {
                    try database.execute("UPDATE manual_queue_items SET updated_at = ? WHERE id = ?", [.text(now), .text(id)])
                }
                if completedAt != nil && DateCoding.date(from: completedAt) == nil {
                    try database.execute("UPDATE manual_queue_items SET completed_at = NULL WHERE id = ?", [.text(id)])
                }
            }
        }
    }

    private func cleanupLegacyGmailData() throws {
        try database.transaction {
            let gmailSourceRows = try database.query("SELECT id FROM sources WHERE kind = ? OR id = ?", [.text("gmail"), .text("gmail")])
            let gmailSourceIds = Set(gmailSourceRows.compactMap { $0["id"] ?? nil } + ["gmail"])
            if !gmailSourceIds.isEmpty {
                let placeholders = Array(repeating: "?", count: gmailSourceIds.count).joined(separator: ", ")
                let values = gmailSourceIds.sorted().map(SQLiteValue.text)
                try database.execute(
                    "DELETE FROM suggestions WHERE source_id IN (\(placeholders)) OR source_app = ?",
                    values + [.text("Gmail")]
                )
                try database.execute("DELETE FROM messages WHERE source_id IN (\(placeholders))", values)
                try database.execute("DELETE FROM threads WHERE source_id IN (\(placeholders))", values)
                try database.execute("DELETE FROM sources WHERE id IN (\(placeholders)) OR kind = ?", values + [.text("gmail")])
            } else {
                try database.execute("DELETE FROM suggestions WHERE source_id = ? OR source_app = ?", [.text("gmail"), .text("Gmail")])
            }

            try database.execute("DELETE FROM permission_health WHERE kind = ?", [.text("gmail")])
            try removeLegacyGmailFromSourcePriority()
        }
    }

    private func removeLegacyGmailFromSourcePriority() throws {
        let rows = try database.query("SELECT id, source_priority FROM user_profiles")
        for row in rows {
            guard
                let id = row["id"] ?? nil,
                let sourcePriority = row["source_priority"] ?? nil
            else {
                continue
            }
            let filteredRawValues = decodeStringArray(sourcePriority).filter { $0 != "gmail" }
            guard filteredRawValues != decodeStringArray(sourcePriority) else { continue }
            let data = (try? JSONEncoder().encode(filteredRawValues)) ?? Data("[]".utf8)
            let encoded = String(data: data, encoding: .utf8) ?? "[]"
            try database.execute(
                "UPDATE user_profiles SET source_priority = ?, updated_at = ? WHERE id = ?",
                [.text(encoded), requiredDate(Date()), .text(id)]
            )
        }
    }

    private func exists(_ sql: String, _ values: [SQLiteValue] = []) throws -> Bool {
        try !database.query(sql, values).isEmpty
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        let rows = try database.query("PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"] ?? nil })
    }

    private func addColumnIfMissing(
        table: String,
        column: String,
        definition: String,
        existingColumns: inout Set<String>
    ) throws {
        guard !existingColumns.contains(column) else { return }
        try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        existingColumns.insert(column)
    }

    private func insertAuditEvent(_ event: AuditEvent) throws {
        try database.execute(
            "INSERT INTO audit_events (id, event_type, entity_id, details, created_at) VALUES (?, ?, ?, ?, ?)",
            [
                .text(event.id),
                .text(event.eventType),
                event.entityId.map(SQLiteValue.text) ?? .null,
                .text(event.details),
                requiredDate(event.createdAt)
            ]
        )
    }

    private func supersedeOlderActiveSuggestions(threadId: String, keeping suggestionId: String, updatedAt: Date) throws {
        try database.execute(
            """
            UPDATE suggestions
            SET state = ?, updated_at = ?
            WHERE thread_id = ?
                AND id != ?
                AND state NOT IN ('dismissed', 'completed', 'superseded')
            """,
            [
                .text(SuggestionState.superseded.rawValue),
                requiredDate(updatedAt),
                .text(threadId),
                .text(suggestionId)
            ]
        )
    }

    private func existingSuggestionRow(
        for draft: SuggestionDraft,
        currentId: String
    ) throws -> (id: String, row: [String: String?])? {
        if let row = try database.query("SELECT * FROM suggestions WHERE id = ?", [.text(currentId)]).first {
            return (currentId, row)
        }

        let legacyId = legacySuggestionID(for: draft)
        guard
            let legacyRow = try database.query(
                """
                SELECT * FROM suggestions
                WHERE id = ?
                    AND source_id = ?
                    AND thread_id = ?
                    AND type = ?
                    AND message_id = ?
                """,
                [
                    .text(legacyId),
                    .text(draft.sourceId),
                    .text(draft.threadId),
                    .text(draft.type.rawValue),
                    .text(draft.messageId)
                ]
            ).first
        else {
            return nil
        }

        return (legacyId, legacyRow)
    }

    private func supersedeActiveSuggestionsNotIn(threadIds: Set<String>, updatedAt: Date) throws {
        let terminalStates = "'dismissed', 'completed', 'superseded'"
        if threadIds.isEmpty {
            try database.execute(
                """
                UPDATE suggestions
                SET state = ?, updated_at = ?
                WHERE state NOT IN (\(terminalStates))
                """,
                [
                    .text(SuggestionState.superseded.rawValue),
                    requiredDate(updatedAt)
                ]
            )
            return
        }

        let placeholders = Array(repeating: "?", count: threadIds.count).joined(separator: ", ")
        let orderedThreadIds = threadIds.sorted()
        try database.execute(
            """
            UPDATE suggestions
            SET state = ?, updated_at = ?
            WHERE state NOT IN (\(terminalStates))
                AND thread_id NOT IN (\(placeholders))
            """,
            [
                .text(SuggestionState.superseded.rawValue),
                requiredDate(updatedAt)
            ] + orderedThreadIds.map(SQLiteValue.text)
        )
    }

    private func updateMessageLabelIfBetter(_ message: Message) throws {
        guard
            !message.isFromUser,
            let existing = try database.query("SELECT sender_label FROM messages WHERE id = ?", [.text(message.id)]).first,
            let existingLabel = existing["sender_label"] ?? nil,
            shouldReplaceSenderLabel(existingLabel, with: message.senderLabel)
        else {
            return
        }

        try database.execute(
            "UPDATE messages SET sender_label = ? WHERE id = ?",
            [
                .text(message.senderLabel),
                .text(message.id)
            ]
        )
    }

    private func updateMessageBodyIfBetter(_ message: Message) throws {
        guard
            let existing = try database.query("SELECT body FROM messages WHERE id = ?", [.text(message.id)]).first,
            let existingBody = existing["body"] ?? nil,
            shouldReplaceMessageBody(existingBody, with: message.body)
        else {
            return
        }

        try database.execute(
            "UPDATE messages SET body = ? WHERE id = ?",
            [
                .text(message.body),
                .text(message.id)
            ]
        )
    }

    private func bestThreadForSave(_ thread: ConversationThread) throws -> ConversationThread {
        guard
            let existing = try database.query("SELECT title, participant_labels FROM threads WHERE id = ?", [.text(thread.id)]).first,
            let existingTitle = existing["title"] ?? nil,
            let existingParticipantLabels = existing["participant_labels"] ?? nil
        else {
            return thread
        }

        var saved = thread
        if ContactHandleNormalizer.looksLikeRawHandle(thread.title) && !ContactHandleNormalizer.looksLikeRawHandle(existingTitle) {
            saved.title = existingTitle
        }

        let decodedExistingParticipants = decodeStringArray(existingParticipantLabels)
        let existingHasName = decodedExistingParticipants.contains { !ContactHandleNormalizer.looksLikeRawHandle($0) }
        let newHasName = thread.participantLabels.contains { !ContactHandleNormalizer.looksLikeRawHandle($0) }
        if existingHasName && !newHasName {
            saved.participantLabels = decodedExistingParticipants
        }

        return saved
    }
}

private func shouldReplaceSenderLabel(_ existing: String, with replacement: String) -> Bool {
    let old = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    let new = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !new.isEmpty, new != old else { return false }
    if old == "Unknown sender" {
        return true
    }
    return ContactHandleNormalizer.looksLikeRawHandle(old) && !ContactHandleNormalizer.looksLikeRawHandle(new)
}

private func shouldReplaceMessageBody(_ existing: String, with replacement: String) -> Bool {
    let old = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    let new = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !new.isEmpty, new != old else { return false }
    let fallbackBodies: Set<String> = [
        "[Sent reply without plain text]",
        "Message without plain text"
    ]
    return fallbackBodies.contains(old) && !fallbackBodies.contains(new)
}

private func source(from row: [String: String?]) throws -> ConversationSource {
    ConversationSource(
        id: try required(row, "id"),
        name: try required(row, "name"),
        kind: try enumValue(row, "kind"),
        health: try enumValue(row, "health"),
        lastSyncAt: DateCoding.date(from: row["last_sync_at"] ?? nil)
    )
}

private func userProfile(from row: [String: String?]) throws -> UserProfile {
    UserProfile(
        id: try required(row, "id"),
        displayName: try required(row, "display_name"),
        timeZoneIdentifier: try required(row, "time_zone_identifier"),
        notificationCadence: try enumValue(row, "notification_cadence"),
        quietHoursStartMinutes: Int(try required(row, "quiet_hours_start_minutes")) ?? 0,
        quietHoursEndMinutes: Int(try required(row, "quiet_hours_end_minutes")) ?? 0,
        sourcePriority: decodeSourceKindArray(try required(row, "source_priority")),
        cloudAIEnabled: try required(row, "cloud_ai_enabled") == "1",
        appColorScheme: try enumValue(row, "app_color_scheme"),
        completedOnboardingAt: DateCoding.date(from: row["completed_onboarding_at"] ?? nil),
        createdAt: try requiredDate(row, "created_at"),
        updatedAt: try requiredDate(row, "updated_at")
    )
}

private func permissionHealth(from row: [String: String?]) throws -> PermissionHealth {
    PermissionHealth(
        kind: try enumValue(row, "kind"),
        state: try enumValue(row, "state"),
        detail: try required(row, "detail"),
        lastCheckedAt: try requiredDate(row, "last_checked_at")
    )
}

private func thread(from row: [String: String?]) throws -> ConversationThread {
    ConversationThread(
        id: try required(row, "id"),
        sourceId: try required(row, "source_id"),
        externalId: try required(row, "external_id"),
        title: try required(row, "title"),
        participantLabels: decodeStringArray(try required(row, "participant_labels")),
        lastMessageAt: try requiredDate(row, "last_message_at"),
        isActive: try required(row, "is_active") == "1"
    )
}

private func message(from row: [String: String?]) throws -> Message {
    Message(
        id: try required(row, "id"),
        sourceId: try required(row, "source_id"),
        threadId: try required(row, "thread_id"),
        externalId: try required(row, "external_id"),
        senderLabel: try required(row, "sender_label"),
        sentAt: try requiredDate(row, "sent_at"),
        body: try required(row, "body"),
        isFromUser: try required(row, "is_from_user") == "1",
        readState: ReadState(rawValue: (row["read_state"] ?? nil) ?? "unknown") ?? .unknown,
        senderId: (row["sender_id"] ?? nil) ?? "unknown",
        eventKind: MessageEventKind(rawValue: (row["event_kind"] ?? nil) ?? "unknown") ?? .unknown,
        contentAvailability: ContentAvailability(rawValue: (row["content_availability"] ?? nil) ?? "unavailable") ?? .unavailable,
        truncated: (row["truncated"] ?? nil) == "1"
    )
}

private func suggestion(from row: [String: String?]) throws -> Suggestion {
    Suggestion(
        id: try required(row, "id"),
        type: try enumValue(row, "type"),
        state: try enumValue(row, "state"),
        title: try required(row, "title"),
        action: SuggestionAction(
            text: try required(row, "action_text"),
            dueDate: DateCoding.date(from: row["due_date"] ?? nil)
        ),
        sourceId: try required(row, "source_id"),
        threadId: try required(row, "thread_id"),
        confidence: Double(try required(row, "confidence")) ?? 0,
        evidence: Evidence(
            sourceApp: try required(row, "source_app"),
            threadTitle: try required(row, "thread_title"),
            messageId: try required(row, "message_id"),
            snippet: try required(row, "evidence_snippet"),
            sourceTimestamp: try requiredDate(row, "source_timestamp")
        ),
        createdAt: try requiredDate(row, "created_at"),
        updatedAt: try requiredDate(row, "updated_at"),
        snoozedUntil: DateCoding.date(from: row["snoozed_until"] ?? nil),
        completedAt: DateCoding.date(from: row["completed_at"] ?? nil)
    )
}

private func manualQueueItem(from row: [String: String?]) throws -> ManualQueueItem {
    ManualQueueItem(
        id: try required(row, "id"),
        kind: try enumValue(row, "kind"),
        title: try required(row, "title").collapsedWhitespace,
        body: (row["body"] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        state: try enumValue(row, "state"),
        createdAt: try requiredDate(row, "created_at"),
        updatedAt: try requiredDate(row, "updated_at"),
        completedAt: DateCoding.date(from: row["completed_at"] ?? nil)
    )
}

private func auditEvent(from row: [String: String?]) throws -> AuditEvent {
    AuditEvent(
        id: try required(row, "id"),
        eventType: try required(row, "event_type"),
        entityId: row["entity_id"] ?? nil,
        details: try required(row, "details"),
        createdAt: try requiredDate(row, "created_at")
    )
}

#if NUDGE_INTERNAL_DIAGNOSTICS
private func geminiDiagnosticRun(from row: [String: String?]) throws -> GeminiDiagnosticRun {
    GeminiDiagnosticRun(
        id: try required(row, "id"),
        model: try required(row, "model"),
        createdAt: try requiredDate(row, "created_at"),
        durationMilliseconds: Int(try required(row, "duration_ms")) ?? 0,
        outcome: try enumValue(row, "outcome"),
        errorCategory: try enumValue(row, "error_category"),
        fallbackUsed: try required(row, "fallback_used") == "1",
        httpStatus: (row["http_status"] ?? nil).flatMap(Int.init),
        candidateCount: Int(try required(row, "candidate_count")) ?? 0,
        decisionCount: Int(try required(row, "decision_count")) ?? 0,
        rankedCount: Int(try required(row, "ranked_count")) ?? 0,
        savedCount: Int(try required(row, "saved_count")) ?? 0,
        candidateThreadIds: decodeStringArray(try required(row, "candidate_thread_ids")),
        candidateMessageIds: decodeStringArray(try required(row, "candidate_message_ids")),
        detail: try required(row, "detail")
    )
}
#endif

private func suggestionID(for draft: SuggestionDraft) -> String {
    let base = [
        draft.sourceId,
        draft.threadId,
        draft.type.rawValue,
        draft.messageId
    ].joined(separator: "|")
    return "suggestion-current-\(base.stableHash)"
}

private func legacySuggestionID(for draft: SuggestionDraft) -> String {
    let base = [
        draft.sourceId,
        draft.threadId
    ].joined(separator: "|")
    return "suggestion-current-\(base.stableHash)"
}

private extension SuggestionState {
    var isQueueActive: Bool {
        self != .completed && self != .dismissed && self != .superseded
    }
}

private func required(_ row: [String: String?], _ column: String) throws -> String {
    guard let value = row[column] else {
        throw MinderStoreError.missingColumn(column)
    }
    guard let unwrapped = value else {
        throw MinderStoreError.invalidStoredValue("Column \(column) is null")
    }
    return unwrapped
}

private func requiredDate(_ row: [String: String?], _ column: String) throws -> Date {
    let string = try required(row, column)
    guard let date = DateCoding.date(from: string) else {
        throw MinderStoreError.invalidStoredValue("Invalid date \(string) in \(column)")
    }
    return date
}

private func requiredDate(_ date: Date) -> SQLiteValue {
    .text(DateCoding.iso8601.string(from: date))
}

private func optionalDate(_ date: Date?) -> SQLiteValue {
    date.map { .text(DateCoding.iso8601.string(from: $0)) } ?? .null
}

private func enumValue<T: RawRepresentable>(_ row: [String: String?], _ column: String) throws -> T where T.RawValue == String {
    let raw = try required(row, column)
    guard let value = T(rawValue: raw) else {
        throw MinderStoreError.invalidStoredValue("Invalid enum value \(raw) in \(column)")
    }
    return value
}

private func encodeStringArray(_ values: [String]) -> String {
    let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
    return String(data: data, encoding: .utf8) ?? "[]"
}

private func encodeSourceKindArray(_ values: [SourceKind]) -> String {
    let data = (try? JSONEncoder().encode(values.map(\.rawValue))) ?? Data("[]".utf8)
    return String(data: data, encoding: .utf8) ?? "[]"
}

private func decodeStringArray(_ value: String) -> [String] {
    guard let data = value.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}

private func decodeSourceKindArray(_ value: String) -> [SourceKind] {
    guard let data = value.data(using: .utf8) else { return [] }
    let rawValues = (try? JSONDecoder().decode([String].self, from: data)) ?? []
    return rawValues.compactMap(SourceKind.init(rawValue:))
}
