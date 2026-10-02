import CSQLite
import Foundation

public struct AppleMessagesSchemaValidation: Equatable {
    public var missingItems: [String]

    public init(missingItems: [String]) {
        self.missingItems = missingItems
    }

    public var isCompatible: Bool {
        missingItems.isEmpty
    }
}

public enum AppleMessagesImportError: Error, LocalizedError, Equatable {
    case databaseMissing(URL)
    case databaseOpenFailed(String)
    case incompatibleSchema([String])

    public var errorDescription: String? {
        switch self {
        case .databaseMissing(let url):
            return "The Apple Messages database was not found at \(url.path)."
        case .databaseOpenFailed(let message):
            return "Nudge could not open the Apple Messages database read-only: \(message)"
        case .incompatibleSchema(let missing):
            return "The Apple Messages database schema is missing: \(missing.joined(separator: ", "))."
        }
    }
}

#if NUDGE_INTERNAL_DIAGNOSTICS
public struct AppleMessagesTextDiagnostics: Equatable {
    public var checkedSince: Date
    public var outgoingWithPlainText: Int
    public var outgoingWithoutPlainText: Int
    public var outgoingWithAttributedBody: Int
    public var outgoingWithoutPlainTextWithAttributedBody: Int
    public var outgoingDecodedFromAttributedBody: Int
    public var outgoingDecodedFromPayloadData: Int
    public var outgoingDecodedFromMessageSummaryInfo: Int
    public var outgoingUnresolvedAfterDecode: Int
    public var attachmentRows: Int
    public var visibleNonTextRows: Int

    public var recoveredOutgoingWithoutPlainTextCount: Int {
        outgoingDecodedFromAttributedBody
            + outgoingDecodedFromPayloadData
            + outgoingDecodedFromMessageSummaryInfo
    }

    public init(
        checkedSince: Date,
        outgoingWithPlainText: Int,
        outgoingWithoutPlainText: Int,
        outgoingWithAttributedBody: Int,
        outgoingWithoutPlainTextWithAttributedBody: Int,
        outgoingDecodedFromAttributedBody: Int = 0,
        outgoingDecodedFromPayloadData: Int = 0,
        outgoingDecodedFromMessageSummaryInfo: Int = 0,
        outgoingUnresolvedAfterDecode: Int = 0,
        attachmentRows: Int,
        visibleNonTextRows: Int
    ) {
        self.checkedSince = checkedSince
        self.outgoingWithPlainText = outgoingWithPlainText
        self.outgoingWithoutPlainText = outgoingWithoutPlainText
        self.outgoingWithAttributedBody = outgoingWithAttributedBody
        self.outgoingWithoutPlainTextWithAttributedBody = outgoingWithoutPlainTextWithAttributedBody
        self.outgoingDecodedFromAttributedBody = outgoingDecodedFromAttributedBody
        self.outgoingDecodedFromPayloadData = outgoingDecodedFromPayloadData
        self.outgoingDecodedFromMessageSummaryInfo = outgoingDecodedFromMessageSummaryInfo
        self.outgoingUnresolvedAfterDecode = outgoingUnresolvedAfterDecode
        self.attachmentRows = attachmentRows
        self.visibleNonTextRows = visibleNonTextRows
    }
}

public struct AppleMessagesDecodeTraceReport: Equatable {
    public var checkedSince: Date
    public var checkedAt: Date
    public var targetTitles: [String]
    public var unmatchedTitles: [String]
    public var threadMatches: [AppleMessagesDecodeTraceThread]

    public var outgoingRowCount: Int {
        threadMatches.reduce(0) { $0 + $1.outgoingRows.count }
    }

    public var placeholderRowCount: Int {
        threadMatches.reduce(0) { count, thread in
            count + thread.outgoingRows.filter { $0.failureReason != nil }.count
        }
    }

    public init(
        checkedSince: Date,
        checkedAt: Date,
        targetTitles: [String],
        unmatchedTitles: [String],
        threadMatches: [AppleMessagesDecodeTraceThread]
    ) {
        self.checkedSince = checkedSince
        self.checkedAt = checkedAt
        self.targetTitles = targetTitles
        self.unmatchedTitles = unmatchedTitles
        self.threadMatches = threadMatches
    }
}

public enum AppleMessagesChatKind: String, Equatable {
    case direct
    case group
    case unknown

    public var displayName: String {
        switch self {
        case .direct:
            return "Direct"
        case .group:
            return "Group"
        case .unknown:
            return "Unknown"
        }
    }
}

public struct AppleMessagesDecodeTraceThread: Identifiable, Equatable {
    public var requestedTitle: String
    public var chatTitle: String
    public var chatGUID: String
    public var chatKind: AppleMessagesChatKind
    public var outgoingRows: [AppleMessagesDecodeTraceRow]

    public var id: String {
        "\(requestedTitle.lowercased()):\(chatGUID)"
    }

    public init(
        requestedTitle: String,
        chatTitle: String,
        chatGUID: String,
        chatKind: AppleMessagesChatKind,
        outgoingRows: [AppleMessagesDecodeTraceRow]
    ) {
        self.requestedTitle = requestedTitle
        self.chatTitle = chatTitle
        self.chatGUID = chatGUID
        self.chatKind = chatKind
        self.outgoingRows = outgoingRows
    }
}

public struct AppleMessagesDecodeTraceRow: Identifiable, Equatable {
    public var messageGUID: String
    public var sentAt: Date
    public var messageTextExists: Bool
    public var messageTextLength: Int
    public var messageTextSnippet: String?
    public var attributedBody: AppleMessagesBlobDecodeTrace
    public var payloadData: AppleMessagesBlobDecodeTrace
    public var messageSummaryInfo: AppleMessagesBlobDecodeTrace
    public var finalBody: String
    public var failureReason: String?

    public var id: String {
        messageGUID
    }

    public init(
        messageGUID: String,
        sentAt: Date,
        messageTextExists: Bool,
        messageTextLength: Int,
        messageTextSnippet: String?,
        attributedBody: AppleMessagesBlobDecodeTrace,
        payloadData: AppleMessagesBlobDecodeTrace,
        messageSummaryInfo: AppleMessagesBlobDecodeTrace,
        finalBody: String,
        failureReason: String?
    ) {
        self.messageGUID = messageGUID
        self.sentAt = sentAt
        self.messageTextExists = messageTextExists
        self.messageTextLength = messageTextLength
        self.messageTextSnippet = messageTextSnippet
        self.attributedBody = attributedBody
        self.payloadData = payloadData
        self.messageSummaryInfo = messageSummaryInfo
        self.finalBody = finalBody
        self.failureReason = failureReason
    }
}

public struct AppleMessagesBlobDecodeTrace: Equatable {
    public var isPresent: Bool
    public var byteLength: Int
    public var hexPrefix: String?
    public var decodedSnippet: String?

    public init(
        isPresent: Bool,
        byteLength: Int,
        hexPrefix: String?,
        decodedSnippet: String?
    ) {
        self.isPresent = isPresent
        self.byteLength = byteLength
        self.hexPrefix = hexPrefix
        self.decodedSnippet = decodedSnippet
    }
}
#endif

public enum AppleMessagesSchemaValidator {
    public static func validate(databaseURL: URL) throws -> AppleMessagesSchemaValidation {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw AppleMessagesImportError.databaseMissing(databaseURL)
        }

        let database = try SQLiteReadOnlyDatabase(url: databaseURL)
        let required: [String: Set<String>] = [
            "message": ["guid", "text", "date", "is_from_me", "handle_id"],
            "chat": ["display_name", "guid"],
            "chat_message_join": ["chat_id", "message_id"],
            "handle": ["id"]
        ]

        var missing: [String] = []
        for (table, columns) in required.sorted(by: { $0.key < $1.key }) {
            let available = try database.tableColumns(table)
            if available.isEmpty {
                missing.append("\(table) table")
                continue
            }
            for column in columns.sorted() where !available.contains(column) {
                missing.append("\(table).\(column)")
            }
        }

        return AppleMessagesSchemaValidation(missingItems: missing)
    }
}

public final class AppleMessagesConversationImporter: ConversationImporting {
    public let sourceKind: SourceKind = .appleMessages
    public let sourceName = "Apple Messages"
    private static let sentReplyWithoutPlainTextPlaceholder = "[Sent reply without plain text]"

    private let databaseURL: URL
    private let maxMessages: Int
    private let contactResolver: ContactResolving

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"),
        maxMessages: Int = 500,
        contactResolver: ContactResolving = NoOpContactResolver()
    ) {
        self.databaseURL = databaseURL
        self.maxMessages = maxMessages
        self.contactResolver = contactResolver
    }

    public static func health(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")) -> PermissionHealth {
        do {
            let validation = try AppleMessagesSchemaValidator.validate(databaseURL: databaseURL)
            if validation.isCompatible {
                return PermissionHealth(kind: .appleMessages, state: .available, detail: "Apple Messages is readable and the local schema looks compatible.")
            }
            return PermissionHealth(kind: .appleMessages, state: .degraded, detail: "Apple Messages is readable, but this schema is missing \(validation.missingItems.joined(separator: ", ")).")
        } catch AppleMessagesImportError.databaseMissing {
            return PermissionHealth(kind: .appleMessages, state: .unsupported, detail: "The local Messages database was not found on this Mac.")
        } catch {
            return PermissionHealth(kind: .appleMessages, state: .missing, detail: "Apple Messages cannot be read yet. Grant Full Disk Access, then check again.")
        }
    }

    public func importRecent(into store: MinderStore, since cutoff: Date) async throws -> ImportResult {
        try performImport(into: store, since: cutoff)
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    public func textDiagnostics(since cutoff: Date) throws -> AppleMessagesTextDiagnostics {
        let validation = try AppleMessagesSchemaValidator.validate(databaseURL: databaseURL)
        guard validation.isCompatible else {
            throw AppleMessagesImportError.incompatibleSchema(validation.missingItems)
        }

        let database = try SQLiteReadOnlyDatabase(url: databaseURL)
        let importSchema = try AppleMessagesImportSchema(database: database)
        let rows = try database.query(
            diagnosticsSQL(schema: importSchema),
            [.int(Int(AppleMessagesDateCodec.messageDateValue(from: cutoff)))]
        )
        let decodeDiagnostics = try outgoingDecodeDiagnostics(database: database, schema: importSchema, cutoff: cutoff)
        let row = rows.first ?? [:]
        return AppleMessagesTextDiagnostics(
            checkedSince: cutoff,
            outgoingWithPlainText: diagnosticInt(row, "outgoing_with_plain_text"),
            outgoingWithoutPlainText: diagnosticInt(row, "outgoing_without_plain_text"),
            outgoingWithAttributedBody: diagnosticInt(row, "outgoing_with_attributed_body"),
            outgoingWithoutPlainTextWithAttributedBody: diagnosticInt(row, "outgoing_without_plain_text_with_attributed_body"),
            outgoingDecodedFromAttributedBody: decodeDiagnostics.attributedBody,
            outgoingDecodedFromPayloadData: decodeDiagnostics.payloadData,
            outgoingDecodedFromMessageSummaryInfo: decodeDiagnostics.messageSummaryInfo,
            outgoingUnresolvedAfterDecode: decodeDiagnostics.unresolved,
            attachmentRows: diagnosticInt(row, "attachment_rows"),
            visibleNonTextRows: diagnosticInt(row, "visible_non_text_rows")
        )
    }
#endif

#if NUDGE_INTERNAL_DIAGNOSTICS
    public func decodeTrace(
        threadTitleMatches: [String] = ["Mom", "Hunter", "ksm"],
        aliasesByTitle: [String: [String]] = [:],
        since cutoff: Date,
        limitPerThread: Int = 12
    ) throws -> AppleMessagesDecodeTraceReport {
        let validation = try AppleMessagesSchemaValidator.validate(databaseURL: databaseURL)
        guard validation.isCompatible else {
            throw AppleMessagesImportError.incompatibleSchema(validation.missingItems)
        }

        let database = try SQLiteReadOnlyDatabase(url: databaseURL)
        let importSchema = try AppleMessagesImportSchema(database: database)
        let targets = threadTitleMatches
            .map(\.collapsedWhitespace)
            .filter { !$0.isEmpty }
        let normalizedAliasesByTitle = aliasesByTitle.reduce(into: [String: [String]]()) { result, pair in
            let key = pair.key.collapsedWhitespace
            guard !key.isEmpty else { return }
            result[key] = uniqueCollapsed(pair.value)
        }
        let boundedLimit = max(1, min(limitPerThread, 50))
        let cutoffValue = Int(AppleMessagesDateCodec.messageDateValue(from: cutoff))
        let chatCandidates = try traceChatCandidates(database: database, schema: importSchema)
        var threadMatches: [AppleMessagesDecodeTraceThread] = []
        var unmatchedTitles: [String] = []

        for target in targets {
            let matchTargets = uniqueCollapsed([target] + (normalizedAliasesByTitle[target] ?? []))
            let chatMatches = chatCandidates
                .filter { $0.matchesAny(matchTargets) }
                .sorted { lhs, rhs in
                    let lhsRank = lhs.bestMatchRank(for: matchTargets)
                    let rhsRank = rhs.bestMatchRank(for: matchTargets)
                    if lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }
                    return lhs.rowID > rhs.rowID
                }
                .prefix(5)

            if chatMatches.isEmpty {
                unmatchedTitles.append(target)
                continue
            }

            for chat in chatMatches {
                let outgoingRows = try database.query(
                    decodeTraceSQL(schema: importSchema),
                    [
                        .int(chat.rowID),
                        .int(cutoffValue),
                        .int(boundedLimit)
                    ]
                )
                let traceRows = outgoingRows.compactMap(decodeTraceRow(from:))
                threadMatches.append(AppleMessagesDecodeTraceThread(
                    requestedTitle: target,
                    chatTitle: chat.resolvedTitle,
                    chatGUID: chat.guid,
                    chatKind: chatKind(from: chat.guid),
                    outgoingRows: traceRows
                ))
            }
        }

        return AppleMessagesDecodeTraceReport(
            checkedSince: cutoff,
            checkedAt: Date(),
            targetTitles: targets,
            unmatchedTitles: unmatchedTitles,
            threadMatches: threadMatches
        )
    }
#endif

    func performImport(into store: MinderStore, since cutoff: Date) throws -> ImportResult {
        let validation = try AppleMessagesSchemaValidator.validate(databaseURL: databaseURL)
        guard validation.isCompatible else {
            throw AppleMessagesImportError.incompatibleSchema(validation.missingItems)
        }

        let database = try SQLiteReadOnlyDatabase(url: databaseURL)
        let importSchema = try AppleMessagesImportSchema(database: database)
        let rows = try database.query(
            importSQL(schema: importSchema),
            [
                .int(Int(AppleMessagesDateCodec.messageDateValue(from: cutoff))),
                .int(maxMessages)
            ]
        )

        let sourceId = ImportIDs.sourceID(for: .appleMessages)
        var threadBuilders: [String: AppleMessagesThreadBuilder] = [:]
        var messages: [Message] = []

        for row in rows {
            guard
                let chatGUID = row["chat_guid"] ?? nil,
                let rawDate = row["date_value"] ?? nil,
                let dateValue = Int64(rawDate)
            else {
                continue
            }

            let threadId = ImportIDs.stableID(prefix: "thread", sourceId: sourceId, externalId: chatGUID)
            let messageGUID = (row["message_guid"] ?? nil)?.nilIfEmpty
            let rowID = (row["message_rowid"] ?? nil) ?? UUID().uuidString
            let externalMessageId = messageGUID ?? "\(rowID)-\(rawDate)"
            let sentAt = AppleMessagesDateCodec.date(fromMessageDateValue: dateValue)
            let isFromUser = (row["is_from_me"] ?? nil) == "1"
            guard let body = messageBody(from: row, isFromUser: isFromUser) else {
                continue
            }
            let rawHandle = (row["handle_id"] ?? nil)?.nilIfEmpty
            let senderLabel = isFromUser
                ? "Me"
                : rawHandle.flatMap { contactResolver.displayName(for: $0) } ?? rawHandle ?? "Unknown sender"

            messages.append(Message(
                id: ImportIDs.stableID(prefix: "message", sourceId: sourceId, externalId: externalMessageId),
                sourceId: sourceId,
                threadId: threadId,
                externalId: externalMessageId,
                senderLabel: senderLabel,
                sentAt: sentAt,
                body: body,
                isFromUser: isFromUser,
                readState: isFromUser ? .unknown : ((row["read_state"] ?? nil) == "1" ? .read : ((row["read_state"] ?? nil) == "0" ? .unread : .unknown)),
                senderId: isFromUser ? "local-user" : ManagedJSON.opaque("sender:" + (rawHandle ?? "unknown")),
                eventKind: ((row["associated_message_type"] ?? nil) ?? "0") == "0" ? .message : .reaction,
                contentAvailability: body == Self.sentReplyWithoutPlainTextPlaceholder || body == "Message without plain text" ? .unavailable : (body.hasPrefix("[Attachment") ? .attachmentOnly : .available)
            ))

            var builder = threadBuilders[threadId] ?? AppleMessagesThreadBuilder(
                id: threadId,
                externalId: chatGUID,
                title: (row["chat_title"] ?? nil)?.nilIfEmpty,
                participants: [],
                lastMessageAt: sentAt
            )
            if !isFromUser {
                builder.participants.insert(senderLabel)
            }
            builder.lastMessageAt = max(builder.lastMessageAt, sentAt)
            threadBuilders[threadId] = builder
        }

        let threads = threadBuilders.values.map { builder in
            ConversationThread(
                id: builder.id,
                sourceId: sourceId,
                externalId: builder.externalId,
                title: builder.resolvedTitle,
                participantLabels: Array(builder.participants).sorted(),
                lastMessageAt: builder.lastMessageAt,
                isActive: true
            )
        }

        let source = ConversationSource(
            id: sourceId,
            name: sourceName,
            kind: .appleMessages,
            health: .available,
            lastSyncAt: Date()
        )

        return try store.saveImport(source: source, threads: threads, messages: messages)
    }

    private func messageBody(from row: [String: String?], isFromUser: Bool) -> String? {
        if let body = (row["body"] ?? nil)?.collapsedWhitespace.nilIfEmpty {
            return body
        }

        if let attributedBody = AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["attributed_body_hex"] ?? nil) {
            return attributedBody
        }

        if let payloadData = AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["payload_data_hex"] ?? nil) {
            return payloadData
        }

        if let messageSummary = AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["message_summary_info_hex"] ?? nil) {
            return messageSummary
        }

        if let attachmentLabel = attachmentBody(from: row) {
            return attachmentLabel
        }

        // Some visible sent replies are stored by Messages without a plain text value.
        // A local marker is enough for ranking to know the user replied.
        if isFromUser {
            return Self.sentReplyWithoutPlainTextPlaceholder
        }

        if isVisibleNonTextMessage(row) {
            return "Message without plain text"
        }

        return nil
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    private func decodeTraceRow(from row: [String: String?]) -> AppleMessagesDecodeTraceRow? {
        guard
            let rawDate = row["date_value"] ?? nil,
            let dateValue = Int64(rawDate)
        else {
            return nil
        }

        let messageRowID = (row["message_rowid"] ?? nil) ?? UUID().uuidString
        let rawMessageText = row["body"] ?? nil
        let messageTextSnippet = snippet(rawMessageText?.collapsedWhitespace.nilIfEmpty)
        let attributedBody = blobDecodeTrace(fromHex: row["attributed_body_hex"] ?? nil)
        let payloadData = blobDecodeTrace(fromHex: row["payload_data_hex"] ?? nil)
        let messageSummaryInfo = blobDecodeTrace(fromHex: row["message_summary_info_hex"] ?? nil)
        let finalBody = messageBody(from: row, isFromUser: true)
            ?? Self.sentReplyWithoutPlainTextPlaceholder

        return AppleMessagesDecodeTraceRow(
            messageGUID: (row["message_guid"] ?? nil)?.nilIfEmpty ?? "ROWID \(messageRowID)",
            sentAt: AppleMessagesDateCodec.date(fromMessageDateValue: dateValue),
            messageTextExists: rawMessageText != nil,
            messageTextLength: rawMessageText?.count ?? 0,
            messageTextSnippet: messageTextSnippet,
            attributedBody: attributedBody,
            payloadData: payloadData,
            messageSummaryInfo: messageSummaryInfo,
            finalBody: snippet(finalBody) ?? finalBody,
            failureReason: decodeTraceFailureReason(
                finalBody: finalBody,
                rawMessageText: rawMessageText,
                attributedBody: attributedBody,
                payloadData: payloadData,
                messageSummaryInfo: messageSummaryInfo
            )
        )
    }

    private func blobDecodeTrace(fromHex hex: String?) -> AppleMessagesBlobDecodeTrace {
        guard let hex = hex?.nilIfEmpty else {
            return AppleMessagesBlobDecodeTrace(
                isPresent: false,
                byteLength: 0,
                hexPrefix: nil,
                decodedSnippet: nil
            )
        }

        let decodedSnippet = snippet(AppleMessagesAttributedBodyDecoder.decodeText(fromHex: hex))
        return AppleMessagesBlobDecodeTrace(
            isPresent: true,
            byteLength: hex.count / 2,
            hexPrefix: String(hex.prefix(64)),
            decodedSnippet: decodedSnippet
        )
    }

    private func decodeTraceFailureReason(
        finalBody: String,
        rawMessageText: String?,
        attributedBody: AppleMessagesBlobDecodeTrace,
        payloadData: AppleMessagesBlobDecodeTrace,
        messageSummaryInfo: AppleMessagesBlobDecodeTrace
    ) -> String? {
        guard finalBody == Self.sentReplyWithoutPlainTextPlaceholder else {
            return nil
        }

        if rawMessageText != nil {
            return "message.text exists, but collapses to an empty string."
        }

        let blobs = [attributedBody, payloadData, messageSummaryInfo]
        if blobs.contains(where: { $0.decodedSnippet != nil }) {
            return "A decoder returned text, but import selection still produced the placeholder."
        }
        if blobs.contains(where: \.isPresent) {
            return "Supported blob data is present, but current decoders returned no text."
        }
        return "No message.text or supported blob columns had data."
    }

    private func diagnosticInt(_ row: [String: String?], _ column: String) -> Int {
        Int((row[column] ?? nil) ?? "0") ?? 0
    }

    private func traceChatCandidates(database: SQLiteReadOnlyDatabase, schema: AppleMessagesImportSchema) throws -> [AppleMessagesTraceChatCandidate] {
        try database.query(traceChatCandidatesSQL(schema: schema)).compactMap { row in
            guard
                let rawRowID = row["chat_rowid"] ?? nil,
                let rowID = Int(rawRowID),
                let guid = row["chat_guid"] ?? nil
            else {
                return nil
            }

            let handles = uniqueCollapsed(
                splitTraceHandles(row["message_handles"] ?? nil)
                    + splitTraceHandles(row["chat_handles"] ?? nil)
                    + directTraceHandles(from: guid)
            )
            let participantLabels = uniqueCollapsed(handles
                .map { contactResolver.displayName(for: $0) ?? $0 }
            )

            return AppleMessagesTraceChatCandidate(
                rowID: rowID,
                guid: guid,
                rawTitle: (row["chat_title"] ?? nil)?.collapsedWhitespace.nilIfEmpty,
                participantHandles: handles,
                participantLabels: participantLabels
            )
        }
    }

    private func traceChatCandidatesSQL(schema: AppleMessagesImportSchema) -> String {
        """
        SELECT
            chat.ROWID AS chat_rowid,
            chat.guid AS chat_guid,
            chat.display_name AS chat_title,
            group_concat(DISTINCT message_handle.id) AS message_handles,
            \(schema.chatHandleSelect)
        FROM chat
        LEFT JOIN chat_message_join ON chat_message_join.chat_id = chat.ROWID
        LEFT JOIN message ON message.ROWID = chat_message_join.message_id
        LEFT JOIN handle AS message_handle ON message_handle.ROWID = message.handle_id
        \(schema.chatHandleJoinSQL)
        GROUP BY chat.ROWID
        """
    }

    private func splitTraceHandles(_ raw: String?) -> [String] {
        (raw ?? "")
            .split(separator: ",")
            .map(String.init)
            .map(\.collapsedWhitespace)
            .filter { !$0.isEmpty }
    }

    private func directTraceHandles(from guid: String) -> [String] {
        guard let separator = guid.range(of: ";-;") else {
            return []
        }
        let rawHandle = String(guid[separator.upperBound...]).collapsedWhitespace
        guard !rawHandle.isEmpty else {
            return []
        }
        return [rawHandle]
    }

    private func uniqueCollapsed(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let collapsed = value.collapsedWhitespace
            guard !collapsed.isEmpty else {
                return nil
            }
            let key = collapsed.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return collapsed
        }
    }
#endif

    private func importSQL(schema: AppleMessagesImportSchema) -> String {
        """
        SELECT *
        FROM (
        SELECT
            chat.guid AS chat_guid,
            chat.display_name AS chat_title,
            message.ROWID AS message_rowid,
            message.guid AS message_guid,
            message.text AS body,
            message.date AS date_value,
            message.is_from_me AS is_from_me,
            \(schema.readStateSelect),
            handle.id AS handle_id,
            \(schema.attributedBodyHexSelect),
            \(schema.cacheHasAttachmentsSelect),
            \(schema.associatedMessageTypeSelect),
            \(schema.balloonBundleIDSelect),
            \(schema.payloadDataHexSelect),
            \(schema.messageSummaryInfoHexSelect),
            \(schema.attachmentSummarySelect)
        FROM message
        JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
        JOIN chat ON chat.ROWID = chat_message_join.chat_id
        LEFT JOIN handle ON handle.ROWID = message.handle_id
        \(schema.attachmentJoinSQL)
        WHERE message.date >= ?
            AND (
                (message.text IS NOT NULL AND length(trim(message.text)) > 0)
                OR message.is_from_me = 1
                OR \(schema.visibleNonTextCondition)
            )
        ORDER BY message.date DESC
        LIMIT ?
        )
        ORDER BY date_value ASC
        """
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    private func decodeTraceSQL(schema: AppleMessagesImportSchema) -> String {
        """
        SELECT *
        FROM (
        SELECT
            chat.guid AS chat_guid,
            chat.display_name AS chat_title,
            message.ROWID AS message_rowid,
            message.guid AS message_guid,
            message.text AS body,
            message.date AS date_value,
            message.is_from_me AS is_from_me,
            \(schema.readStateSelect),
            handle.id AS handle_id,
            \(schema.attributedBodyHexSelect),
            \(schema.cacheHasAttachmentsSelect),
            \(schema.associatedMessageTypeSelect),
            \(schema.balloonBundleIDSelect),
            \(schema.payloadDataHexSelect),
            \(schema.messageSummaryInfoHexSelect),
            \(schema.attachmentSummarySelect)
        FROM message
        JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
        JOIN chat ON chat.ROWID = chat_message_join.chat_id
        LEFT JOIN handle ON handle.ROWID = message.handle_id
        \(schema.attachmentJoinSQL)
        WHERE chat.ROWID = ?
            AND message.date >= ?
            AND message.is_from_me = 1
        ORDER BY message.date DESC
        LIMIT ?
        )
        ORDER BY date_value ASC
        """
    }

    private func diagnosticsSQL(schema: AppleMessagesImportSchema) -> String {
        let textPresent = "(message.text IS NOT NULL AND length(trim(message.text)) > 0)"
        let textMissing = "(message.text IS NULL OR length(trim(message.text)) = 0)"
        return """
        SELECT
            SUM(CASE WHEN message.is_from_me = 1 AND \(textPresent) THEN 1 ELSE 0 END) AS outgoing_with_plain_text,
            SUM(CASE WHEN message.is_from_me = 1 AND \(textMissing) THEN 1 ELSE 0 END) AS outgoing_without_plain_text,
            SUM(CASE WHEN message.is_from_me = 1 AND \(schema.attributedBodyPresentCondition) THEN 1 ELSE 0 END) AS outgoing_with_attributed_body,
            SUM(CASE WHEN message.is_from_me = 1 AND \(textMissing) AND \(schema.attributedBodyPresentCondition) THEN 1 ELSE 0 END) AS outgoing_without_plain_text_with_attributed_body,
            SUM(CASE WHEN \(schema.attachmentPresentCondition) THEN 1 ELSE 0 END) AS attachment_rows,
            SUM(CASE WHEN \(schema.visibleNonTextCondition) THEN 1 ELSE 0 END) AS visible_non_text_rows
        FROM message
        \(schema.attachmentJoinSQL)
        WHERE message.date >= ?
        """
    }

    private func chatKind(from guid: String) -> AppleMessagesChatKind {
        if guid.contains(";+;") {
            return .group
        }
        if guid.contains(";-;") {
            return .direct
        }
        return .unknown
    }

    private func snippet(_ text: String?, maxLength: Int = 180) -> String? {
        guard let text = text?.collapsedWhitespace.nilIfEmpty else {
            return nil
        }
        guard text.count > maxLength else {
            return text
        }
        return "\(text.prefix(maxLength))..."
    }

    private func outgoingDecodeDiagnostics(
        database: SQLiteReadOnlyDatabase,
        schema: AppleMessagesImportSchema,
        cutoff: Date
    ) throws -> AppleMessagesDecodeDiagnostics {
        let rows = try database.query(
            outgoingDecodeDiagnosticsSQL(schema: schema),
            [.int(Int(AppleMessagesDateCodec.messageDateValue(from: cutoff)))]
        )
        var diagnostics = AppleMessagesDecodeDiagnostics()
        for row in rows {
            if AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["attributed_body_hex"] ?? nil) != nil {
                diagnostics.attributedBody += 1
            } else if AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["payload_data_hex"] ?? nil) != nil {
                diagnostics.payloadData += 1
            } else if AppleMessagesAttributedBodyDecoder.decodeText(fromHex: row["message_summary_info_hex"] ?? nil) != nil {
                diagnostics.messageSummaryInfo += 1
            } else {
                diagnostics.unresolved += 1
            }
        }
        return diagnostics
    }

    private func outgoingDecodeDiagnosticsSQL(schema: AppleMessagesImportSchema) -> String {
        let textMissing = "(message.text IS NULL OR length(trim(message.text)) = 0)"
        return """
        SELECT
            message.guid AS message_guid,
            \(schema.attributedBodyHexSelect),
            \(schema.payloadDataHexSelect),
            \(schema.messageSummaryInfoHexSelect)
        FROM message
        WHERE message.date >= ?
            AND message.is_from_me = 1
            AND \(textMissing)
        """
    }
#endif

    private func attachmentBody(from row: [String: String?]) -> String? {
        let summary = (row["attachment_summary"] ?? nil)?.lowercased().nilIfEmpty
        let hasAttachment = (row["cache_has_attachments"] ?? nil) == "1" || summary != nil
        guard hasAttachment else { return nil }

        guard let summary else {
            return "File attachment"
        }

        if summary.contains("image") || summary.contains("jpeg") || summary.contains("jpg") || summary.contains("png") || summary.contains("gif") || summary.contains("heic") {
            return "Image attachment"
        }
        if summary.contains("video") || summary.contains("movie") || summary.contains("mp4") || summary.contains("mov") {
            return "Video attachment"
        }
        if summary.contains("audio") || summary.contains("voice") || summary.contains("m4a") || summary.contains("caf") || summary.contains("mp3") {
            return "Audio message"
        }
        return "File attachment"
    }

    private func isVisibleNonTextMessage(_ row: [String: String?]) -> Bool {
        if
            let rawType = (row["associated_message_type"] ?? nil)?.nilIfEmpty,
            rawType != "0"
        {
            return true
        }
        if (row["balloon_bundle_id"] ?? nil)?.collapsedWhitespace.nilIfEmpty != nil {
            return true
        }
        return false
    }
}

#if NUDGE_INTERNAL_DIAGNOSTICS
private struct AppleMessagesDecodeDiagnostics {
    var attributedBody = 0
    var payloadData = 0
    var messageSummaryInfo = 0
    var unresolved = 0
}

private struct AppleMessagesTraceChatCandidate {
    var rowID: Int
    var guid: String
    var rawTitle: String?
    var participantHandles: [String]
    var participantLabels: [String]

    var resolvedTitle: String {
        if let rawTitle {
            return rawTitle
        }
        if !participantLabels.isEmpty {
            return participantLabels.sorted().joined(separator: ", ")
        }
        return guid
    }

    func matches(_ target: String) -> Bool {
        let normalizedTarget = target.lowercased()
        guard !normalizedTarget.isEmpty else {
            return false
        }
        return searchableValues.contains { $0.lowercased().contains(normalizedTarget) }
    }

    func matchesAny(_ targets: [String]) -> Bool {
        targets.contains { matches($0) }
    }

    func matchRank(for target: String) -> Int {
        let normalizedTarget = target.lowercased()
        let values = searchableValues.map { $0.lowercased() }
        if values.contains(normalizedTarget) {
            return 0
        }
        if values.contains(where: { $0.hasPrefix(normalizedTarget) }) {
            return 1
        }
        return 2
    }

    func bestMatchRank(for targets: [String]) -> Int {
        targets.map { matchRank(for: $0) }.min() ?? Int.max
    }

    private var searchableValues: [String] {
        ([resolvedTitle, guid] + participantLabels + participantHandles)
            .map(\.collapsedWhitespace)
            .filter { !$0.isEmpty }
    }
}
#endif

private struct AppleMessagesImportSchema {
    var messageColumns: Set<String>
    var chatMessageJoinColumns: Set<String>
#if NUDGE_INTERNAL_DIAGNOSTICS
    var chatHandleJoinColumns: Set<String>
#endif
    var attachmentColumns: Set<String>

    init(database: SQLiteReadOnlyDatabase) throws {
        self.messageColumns = try database.tableColumns("message")
        self.chatMessageJoinColumns = try database.tableColumns("message_attachment_join")
#if NUDGE_INTERNAL_DIAGNOSTICS
        self.chatHandleJoinColumns = try database.tableColumns("chat_handle_join")
#endif
        self.attachmentColumns = try database.tableColumns("attachment")
    }

    var readStateSelect: String {
        messageColumns.contains("is_read") ? "message.is_read AS read_state" : "NULL AS read_state"
    }

    var cacheHasAttachmentsSelect: String {
        messageColumns.contains("cache_has_attachments")
            ? "message.cache_has_attachments AS cache_has_attachments"
            : "0 AS cache_has_attachments"
    }

    var associatedMessageTypeSelect: String {
        messageColumns.contains("associated_message_type")
            ? "message.associated_message_type AS associated_message_type"
            : "0 AS associated_message_type"
    }

    var balloonBundleIDSelect: String {
        messageColumns.contains("balloon_bundle_id")
            ? "message.balloon_bundle_id AS balloon_bundle_id"
            : "NULL AS balloon_bundle_id"
    }

    var attachmentSummarySelect: String {
        canJoinAttachments ? "attachment_info.attachment_summary AS attachment_summary" : "NULL AS attachment_summary"
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    var chatHandleSelect: String {
        canJoinChatHandles ? "group_concat(DISTINCT chat_handle.id) AS chat_handles" : "NULL AS chat_handles"
    }

    var chatHandleJoinSQL: String {
        guard canJoinChatHandles else { return "" }
        return """
        LEFT JOIN chat_handle_join ON chat_handle_join.chat_id = chat.ROWID
        LEFT JOIN handle AS chat_handle ON chat_handle.ROWID = chat_handle_join.handle_id
        """
    }
#endif

    var attributedBodyHexSelect: String {
        messageColumns.contains("attributedBody")
            ? "hex(message.attributedBody) AS attributed_body_hex"
            : "NULL AS attributed_body_hex"
    }

    var payloadDataHexSelect: String {
        messageColumns.contains("payload_data")
            ? "hex(message.payload_data) AS payload_data_hex"
            : "NULL AS payload_data_hex"
    }

    var messageSummaryInfoHexSelect: String {
        messageColumns.contains("message_summary_info")
            ? "hex(message.message_summary_info) AS message_summary_info_hex"
            : "NULL AS message_summary_info_hex"
    }

    var attachmentJoinSQL: String {
        guard canJoinAttachments else { return "" }
        return """
        LEFT JOIN (
            SELECT
                message_attachment_join.message_id AS joined_message_id,
                group_concat(\(attachmentDetailExpression), ' ') AS attachment_summary
            FROM message_attachment_join
            JOIN attachment ON attachment.ROWID = message_attachment_join.attachment_id
            GROUP BY message_attachment_join.message_id
        ) attachment_info ON attachment_info.joined_message_id = message.ROWID
        """
    }

    var visibleNonTextCondition: String {
        let conditions = [
            messageColumns.contains("cache_has_attachments") ? "message.cache_has_attachments = 1" : nil,
            messageColumns.contains("associated_message_type") ? "(message.associated_message_type IS NOT NULL AND message.associated_message_type != 0)" : nil,
            messageColumns.contains("balloon_bundle_id") ? "(message.balloon_bundle_id IS NOT NULL AND length(trim(message.balloon_bundle_id)) > 0)" : nil,
            canJoinAttachments ? "attachment_info.attachment_summary IS NOT NULL" : nil
        ].compactMap { $0 }

        return conditions.isEmpty ? "0" : conditions.joined(separator: " OR ")
    }

    var attributedBodyPresentCondition: String {
        messageColumns.contains("attributedBody")
            ? "(message.attributedBody IS NOT NULL AND length(message.attributedBody) > 0)"
            : "0"
    }

    var attachmentPresentCondition: String {
        let conditions = [
            messageColumns.contains("cache_has_attachments") ? "message.cache_has_attachments = 1" : nil,
            canJoinAttachments ? "attachment_info.attachment_summary IS NOT NULL" : nil
        ].compactMap { $0 }

        return conditions.isEmpty ? "0" : conditions.joined(separator: " OR ")
    }

    private var canJoinAttachments: Bool {
        chatMessageJoinColumns.contains("message_id")
            && chatMessageJoinColumns.contains("attachment_id")
            && !attachmentColumns.isEmpty
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    private var canJoinChatHandles: Bool {
        chatHandleJoinColumns.contains("chat_id")
            && chatHandleJoinColumns.contains("handle_id")
    }
#endif

    private var attachmentDetailExpression: String {
        let expressions = [
            attachmentColumns.contains("mime_type") ? "NULLIF(attachment.mime_type, '')" : nil,
            attachmentColumns.contains("uti") ? "NULLIF(attachment.uti, '')" : nil,
            attachmentColumns.contains("transfer_name") ? "NULLIF(attachment.transfer_name, '')" : nil,
            attachmentColumns.contains("filename") ? "NULLIF(attachment.filename, '')" : nil
        ].compactMap { $0 }

        if expressions.isEmpty {
            return "'attachment'"
        }
        if expressions.count == 1 {
            return expressions[0]
        }
        return "COALESCE(\(expressions.joined(separator: ", ")))"
    }
}

public enum AppleMessagesAttributedBodyDecoder {
    public static func decodeText(fromHex hex: String?) -> String? {
        guard let hex = hex?.nilIfEmpty, let data = Data(hexEncoded: hex) else {
            return nil
        }
        return decodeText(from: data)
    }

    public static func decodeText(from data: Data) -> String? {
        if let text = normalizedText(from: decodeKeyedArchivedObject(from: data)) {
            return text
        }
        if let text = normalizedText(from: decodeLegacyArchivedObject(from: data)) {
            return text
        }
        if let text = decodePropertyListText(from: data) {
            return text
        }
        if let text = decodeEmbeddedPlainText(from: data) {
            return text
        }
        return nil
    }

    private static func normalizedText(from object: Any?) -> String? {
        if let attributed = object as? NSAttributedString {
            return attributed.string.collapsedWhitespace.nilIfEmpty
        }
        if let string = object as? String {
            return string.collapsedWhitespace.nilIfEmpty
        }
        if let string = object as? NSString {
            return (string as String).collapsedWhitespace.nilIfEmpty
        }
        return nil
    }

    private static func decodeKeyedArchivedObject(from data: Data) -> Any? {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        } catch {
            return nil
        }
    }

    private static func decodeLegacyArchivedObject(from data: Data) -> Any? {
        guard data.starts(with: Data([0x04, 0x0b]) + Data("streamtyped".utf8)) else {
            return nil
        }
        return NSUnarchiver.unarchiveObject(with: data)
    }

    private static func decodePropertyListText(from data: Data) -> String? {
        guard data.starts(with: Data("bplist".utf8)) else {
            return nil
        }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return bestTextCandidate(from: plistStrings(in: object), minimumScore: 1)
    }

    private static func plistStrings(in object: Any) -> [String] {
        if let string = object as? String {
            return [string]
        }
        if let string = object as? NSString {
            return [string as String]
        }
        if let array = object as? [Any] {
            return array.flatMap(plistStrings)
        }
        if let dictionary = object as? [AnyHashable: Any] {
            return dictionary.values.flatMap(plistStrings)
        }
        return []
    }

    private static func decodeEmbeddedPlainText(from data: Data) -> String? {
        let candidates = utf8StringCandidates(from: data)
            + utf16StringCandidates(from: data, encoding: .utf16LittleEndian)
            + utf16StringCandidates(from: data, encoding: .utf16BigEndian)
        return bestTextCandidate(from: candidates, minimumScore: 8)
    }

    private static func utf8StringCandidates(from data: Data) -> [String] {
        var candidates: [String] = []
        var buffer = Data()

        func flush() {
            guard buffer.count >= 2 else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            let decoded = String(decoding: buffer, as: UTF8.self)
            candidates.append(contentsOf: decoded.components(separatedBy: "\u{FFFD}"))
            buffer.removeAll(keepingCapacity: true)
        }

        for byte in data {
            if byte == 0x09 || byte == 0x0a || byte == 0x0d || byte >= 0x20 {
                buffer.append(byte)
            } else {
                flush()
            }
        }
        flush()

        return candidates
    }

    private static func utf16StringCandidates(from data: Data, encoding: String.Encoding) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }

        var candidates: [String] = []
        for alignment in 0...1 {
            var start: Int?
            var index = alignment

            func flush(through end: Int) {
                guard let rangeStart = start, end - rangeStart >= 4 else {
                    start = nil
                    return
                }
                let slice = Data(bytes[rangeStart..<end])
                if let string = String(data: slice, encoding: encoding) {
                    candidates.append(string)
                }
                start = nil
            }

            while index + 1 < bytes.count {
                let codeUnit: UInt16
                switch encoding {
                case .utf16LittleEndian:
                    codeUnit = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                default:
                    codeUnit = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
                }

                if isLikelyTextUTF16CodeUnit(codeUnit) {
                    if start == nil {
                        start = index
                    }
                } else {
                    flush(through: index)
                }
                index += 2
            }
            flush(through: index)
        }

        return candidates
    }

    private static func isLikelyTextUTF16CodeUnit(_ value: UInt16) -> Bool {
        value == 0x09
            || value == 0x0a
            || value == 0x0d
            || (value >= 0x20 && value <= 0xfffd)
    }

    private static func bestTextCandidate(from strings: [String], minimumScore: Int) -> String? {
        strings
            .compactMap { textCandidate(from: $0) }
            .filter { $0.score >= minimumScore }
            .max { lhs, rhs in
                lhs.score == rhs.score ? lhs.text.count < rhs.text.count : lhs.score < rhs.score
            }?
            .text
    }

    private static func textCandidate(from raw: String) -> (text: String, score: Int)? {
        guard let text = raw.collapsedWhitespace.nilIfEmpty else {
            return nil
        }
        guard text.count <= 4_000, containsHumanContent(text), !isArchiveMetadata(text) else {
            return nil
        }

        var score = min(text.count, 120)
        if text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
            score += 40
        }
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!,;:")) != nil {
            score += 20
        }
        if text.count <= 3 {
            score -= 4
        }
        if looksLikeTechnicalIdentifier(text) {
            score -= 60
        }
        return score > 0 ? (text, score) : nil
    }

    private static func containsHumanContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || scalar.properties.isEmoji
        }
    }

    private static func isArchiveMetadata(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let exactMetadata: Set<String> = [
            "$archiver",
            "$class",
            "$classes",
            "$null",
            "$objects",
            "$top",
            "ns.attributes",
            "ns.keys",
            "ns.objects",
            "ns.string",
            "nsattributeinfo",
            "nsattributedstring",
            "nscolor",
            "nsfont",
            "nsfontnameattributename",
            "nsforegroundcolorattributename",
            "nsmutableattributedstring",
            "nsmutablestring",
            "nsobject",
            "nsparagraphstyle",
            "nsstring",
            "streamtyped"
        ]
        if exactMetadata.contains(normalized) {
            return true
        }
        if normalized.hasPrefix("$") || normalized.hasPrefix("com.apple.") {
            return true
        }
        if normalized.contains("streamtyped")
            || normalized.contains("nskeyedarchive")
            || normalized.contains("nsattributedstring")
            || normalized.contains("immessagepart")
        {
            return true
        }
        return looksLikeTechnicalIdentifier(text) && text.count > 12
    }

    private static func looksLikeTechnicalIdentifier(_ text: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.$"))
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        return text.hasPrefix("NS")
            || text.hasPrefix("__")
            || text.contains(".")
            || text.contains("_")
            || text.contains("$")
    }
}

private extension Data {
    init?(hexEncoded hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let nextIndex = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum AppleMessagesDateCodec {
    private static let appleEpochOffset: TimeInterval = 978_307_200

    public static func messageDateValue(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000)
    }

    public static func date(fromMessageDateValue value: Int64) -> Date {
        let absolute = Double(value)
        if abs(absolute) > 10_000_000_000_000 {
            return Date(timeIntervalSince1970: absolute / 1_000_000_000 + appleEpochOffset)
        }
        if abs(absolute) > 10_000_000_000 {
            return Date(timeIntervalSince1970: absolute / 1_000 + appleEpochOffset)
        }
        return Date(timeIntervalSince1970: absolute + appleEpochOffset)
    }
}

private struct AppleMessagesThreadBuilder {
    var id: String
    var externalId: String
    var title: String?
    var participants: Set<String>
    var lastMessageAt: Date

    var resolvedTitle: String {
        if let title = title?.collapsedWhitespace.nilIfEmpty {
            return title
        }
        if !participants.isEmpty {
            return participants.sorted().joined(separator: ", ")
        }
        return "Messages Chat"
    }
}

final class SQLiteReadOnlyDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(database)
            throw AppleMessagesImportError.databaseOpenFailed(message)
        }
        handle = database
    }

    deinit {
        sqlite3_close(handle)
    }

    func tableColumns(_ table: String) throws -> Set<String> {
        let rows = try query("PRAGMA table_info(\(try quotedIdentifier(table)))")
        return Set(rows.compactMap { $0["name"] ?? nil })
    }

    func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[String: String?]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }

        var rows: [[String: String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return rows
            }
            guard result == SQLITE_ROW else {
                throw SQLiteError.stepFailed(lastErrorMessage)
            }

            var row: [String: String?] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, column) else { continue }
                let key = String(cString: name)
                if sqlite3_column_type(statement, column) == SQLITE_NULL {
                    row[key] = nil
                } else if let text = sqlite3_column_text(statement, column) {
                    row[key] = String(cString: text)
                } else {
                    row[key] = nil
                }
            }
            rows.append(row)
        }
    }

    private func prepare(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(lastErrorMessage)
        }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .text(let string):
                result = sqlite3_bind_text(statement, position, string, -1, SQLITE_TRANSIENT)
            case .int(let int):
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(int))
            case .double(let double):
                result = sqlite3_bind_double(statement, position, double)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }

            if result != SQLITE_OK {
                throw SQLiteError.bindFailed(lastErrorMessage)
            }
        }

        return statement
    }

    private func quotedIdentifier(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SQLiteError.prepareFailed("Invalid SQLite identifier \(value)")
        }
        return "\"\(value)\""
    }

    private var lastErrorMessage: String {
        guard let handle else { return "Database handle is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}
