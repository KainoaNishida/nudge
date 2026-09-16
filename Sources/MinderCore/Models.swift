import Foundation

public enum SourceKind: String, Codable, CaseIterable, Hashable {
    case sample
    case appleMessages
}

public enum HealthState: String, Codable, CaseIterable, Hashable {
    case available
    case missing
    case degraded
    case revoked
    case unsupported
}

public enum NotificationCadence: String, Codable, CaseIterable, Hashable {
    case immediately
    case hourlyDigest
    case dailyDigest
    case quiet

    public var displayName: String {
        switch self {
        case .immediately: return "Immediately"
        case .hourlyDigest: return "Hourly Digest"
        case .dailyDigest: return "Daily Digest"
        case .quiet: return "Quiet"
        }
    }
}

public enum PermissionKind: String, Codable, CaseIterable, Hashable {
    case fullDiskAccess
    case appleMessages
    case contacts
    case notifications
    case calendar
    case reminders
    case cloudAI

    public var displayName: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .appleMessages: return "Apple Messages"
        case .contacts: return "Contacts"
        case .notifications: return "Notifications"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .cloudAI: return "Cloud AI"
        }
    }
}

public enum SuggestionType: String, Codable, CaseIterable, Hashable {
    case staleReply
    case unansweredQuestion
    case deadline
    case calendarEvent
    case reminder
    case promisedTask
    case importantContext
    case followUpNudge

    public var displayName: String {
        switch self {
        case .staleReply: return "Stale Reply"
        case .unansweredQuestion: return "Unanswered Question"
        case .deadline: return "Deadline"
        case .calendarEvent: return "Calendar Event"
        case .reminder: return "Reminder"
        case .promisedTask: return "Promised Task"
        case .importantContext: return "Important Context"
        case .followUpNudge: return "Follow-Up"
        }
    }
}

public enum SuggestionState: String, Codable, CaseIterable, Hashable {
    case new
    case viewed
    case confirmed
    case dismissed
    case snoozed
    case completed
    case failed
    case needsPermission
    case superseded

    public var displayName: String {
        switch self {
        case .new: return "New"
        case .viewed: return "Viewed"
        case .confirmed: return "Confirmed"
        case .dismissed: return "Dismissed"
        case .snoozed: return "Snoozed"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .needsPermission: return "Needs Permission"
        case .superseded: return "Superseded"
        }
    }
}

public enum ManualQueueItemKind: String, Codable, CaseIterable, Hashable {
    case todo
    case note

    public var displayName: String {
        switch self {
        case .todo: return "To-do"
        case .note: return "Note"
        }
    }
}

public enum ManualQueueItemState: String, Codable, CaseIterable, Hashable {
    case active
    case completed

    public var displayName: String {
        switch self {
        case .active: return "Active"
        case .completed: return "Completed"
        }
    }
}

public enum AppColorScheme: String, Codable, CaseIterable, Hashable {
    case ocean
    case sky
    case cyan
    case teal
    case forest
    case mint
    case lime
    case yellow
    case plum
    case indigo
    case pink
    case ruby
    case ember
    case graphite

    public var displayName: String {
        switch self {
        case .ocean: return "Blue"
        case .sky: return "Sky"
        case .cyan: return "Cyan"
        case .teal: return "Teal"
        case .forest: return "Green"
        case .mint: return "Mint"
        case .lime: return "Lime"
        case .yellow: return "Yellow"
        case .plum: return "Purple"
        case .indigo: return "Indigo"
        case .pink: return "Pink"
        case .ruby: return "Ruby"
        case .ember: return "Orange"
        case .graphite: return "Graphite"
        }
    }
}

public struct ConversationSource: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var kind: SourceKind
    public var health: HealthState
    public var lastSyncAt: Date?

    public init(id: String, name: String, kind: SourceKind, health: HealthState = .available, lastSyncAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.health = health
        self.lastSyncAt = lastSyncAt
    }
}

#if NUDGE_INTERNAL_DIAGNOSTICS
public enum GeminiDiagnosticOutcome: String, Codable, CaseIterable, Hashable {
    case success
    case failure
    case skipped
}

public enum GeminiDiagnosticErrorCategory: String, Codable, CaseIterable, Hashable {
    case missingConfig
    case disabled
    case noCandidates
    case network
    case http
    case missingOutput
    case invalidJSON
    case invalidEvidence
    case success
}

public struct GeminiDiagnosticRun: Identifiable, Codable, Equatable {
    public var id: String
    public var model: String
    public var createdAt: Date
    public var durationMilliseconds: Int
    public var outcome: GeminiDiagnosticOutcome
    public var errorCategory: GeminiDiagnosticErrorCategory
    public var fallbackUsed: Bool
    public var httpStatus: Int?
    public var candidateCount: Int
    public var decisionCount: Int
    public var rankedCount: Int
    public var savedCount: Int
    public var candidateThreadIds: [String]
    public var candidateMessageIds: [String]
    public var detail: String

    public init(
        id: String = UUID().uuidString,
        model: String,
        createdAt: Date = Date(),
        durationMilliseconds: Int,
        outcome: GeminiDiagnosticOutcome,
        errorCategory: GeminiDiagnosticErrorCategory,
        fallbackUsed: Bool,
        httpStatus: Int? = nil,
        candidateCount: Int,
        decisionCount: Int,
        rankedCount: Int,
        savedCount: Int,
        candidateThreadIds: [String],
        candidateMessageIds: [String],
        detail: String
    ) {
        self.id = id
        self.model = model
        self.createdAt = createdAt
        self.durationMilliseconds = durationMilliseconds
        self.outcome = outcome
        self.errorCategory = errorCategory
        self.fallbackUsed = fallbackUsed
        self.httpStatus = httpStatus
        self.candidateCount = candidateCount
        self.decisionCount = decisionCount
        self.rankedCount = rankedCount
        self.savedCount = savedCount
        self.candidateThreadIds = candidateThreadIds
        self.candidateMessageIds = candidateMessageIds
        self.detail = detail
    }
}
#endif

public struct UserProfile: Codable, Equatable {
    public static let defaultID = "default"

    public var id: String
    public var displayName: String
    public var timeZoneIdentifier: String
    public var notificationCadence: NotificationCadence
    public var quietHoursStartMinutes: Int
    public var quietHoursEndMinutes: Int
    public var sourcePriority: [SourceKind]
    public var cloudAIEnabled: Bool
    public var appColorScheme: AppColorScheme
    public var completedOnboardingAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var hasCompletedOnboarding: Bool {
        completedOnboardingAt != nil
    }

    public init(
        id: String = UserProfile.defaultID,
        displayName: String = "",
        timeZoneIdentifier: String = TimeZone.current.identifier,
        notificationCadence: NotificationCadence = .hourlyDigest,
        quietHoursStartMinutes: Int = 22 * 60,
        quietHoursEndMinutes: Int = 7 * 60,
        sourcePriority: [SourceKind] = [.appleMessages, .sample],
        cloudAIEnabled: Bool = false,
        appColorScheme: AppColorScheme = .ocean,
        completedOnboardingAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.notificationCadence = notificationCadence
        self.quietHoursStartMinutes = quietHoursStartMinutes
        self.quietHoursEndMinutes = quietHoursEndMinutes
        self.sourcePriority = sourcePriority
        self.cloudAIEnabled = cloudAIEnabled
        self.appColorScheme = appColorScheme
        self.completedOnboardingAt = completedOnboardingAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PermissionHealth: Identifiable, Codable, Equatable {
    public var kind: PermissionKind
    public var state: HealthState
    public var detail: String
    public var lastCheckedAt: Date

    public var id: String {
        kind.rawValue
    }

    public init(kind: PermissionKind, state: HealthState, detail: String, lastCheckedAt: Date = Date()) {
        self.kind = kind
        self.state = state
        self.detail = detail
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct ConversationThread: Identifiable, Codable, Equatable {
    public var id: String
    public var sourceId: String
    public var externalId: String
    public var title: String
    public var participantLabels: [String]
    public var lastMessageAt: Date
    public var isActive: Bool

    public init(
        id: String,
        sourceId: String,
        externalId: String,
        title: String,
        participantLabels: [String],
        lastMessageAt: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.sourceId = sourceId
        self.externalId = externalId
        self.title = title
        self.participantLabels = participantLabels
        self.lastMessageAt = lastMessageAt
        self.isActive = isActive
    }
}

public struct Message: Identifiable, Codable, Equatable {
    public var id: String
    public var sourceId: String
    public var threadId: String
    public var externalId: String
    public var senderLabel: String
    public var sentAt: Date
    public var body: String
    public var isFromUser: Bool

    public init(
        id: String,
        sourceId: String,
        threadId: String,
        externalId: String,
        senderLabel: String,
        sentAt: Date,
        body: String,
        isFromUser: Bool
    ) {
        self.id = id
        self.sourceId = sourceId
        self.threadId = threadId
        self.externalId = externalId
        self.senderLabel = senderLabel
        self.sentAt = sentAt
        self.body = body
        self.isFromUser = isFromUser
    }
}

public struct Evidence: Codable, Equatable {
    public var sourceApp: String
    public var threadTitle: String
    public var messageId: String
    public var snippet: String
    public var sourceTimestamp: Date

    public init(sourceApp: String, threadTitle: String, messageId: String, snippet: String, sourceTimestamp: Date) {
        self.sourceApp = sourceApp
        self.threadTitle = threadTitle
        self.messageId = messageId
        self.snippet = snippet
        self.sourceTimestamp = sourceTimestamp
    }
}

public struct SuggestionAction: Codable, Equatable {
    public var text: String
    public var dueDate: Date?

    public init(text: String, dueDate: Date? = nil) {
        self.text = text
        self.dueDate = dueDate
    }
}

public struct Suggestion: Identifiable, Codable, Equatable {
    public var id: String
    public var type: SuggestionType
    public var state: SuggestionState
    public var title: String
    public var action: SuggestionAction
    public var sourceId: String
    public var threadId: String
    public var confidence: Double
    public var evidence: Evidence
    public var createdAt: Date
    public var updatedAt: Date
    public var snoozedUntil: Date?
    public var completedAt: Date?

    public var confidenceLabel: String {
        if confidence >= 0.85 { return "High" }
        if confidence >= 0.60 { return "Medium" }
        if confidence >= 0.15 { return "Low" }
        return "Suppressed"
    }

    public init(
        id: String,
        type: SuggestionType,
        state: SuggestionState = .new,
        title: String,
        action: SuggestionAction,
        sourceId: String,
        threadId: String,
        confidence: Double,
        evidence: Evidence,
        createdAt: Date,
        updatedAt: Date,
        snoozedUntil: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.state = state
        self.title = title
        self.action = action
        self.sourceId = sourceId
        self.threadId = threadId
        self.confidence = confidence
        self.evidence = evidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.snoozedUntil = snoozedUntil
        self.completedAt = completedAt
    }
}

public struct ManualQueueItem: Identifiable, Codable, Equatable {
    public var id: String
    public var kind: ManualQueueItemKind
    public var title: String
    public var body: String?
    public var state: ManualQueueItemState
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: ManualQueueItemKind,
        title: String,
        body: String? = nil,
        state: ManualQueueItemState = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public struct SuggestionDraft: Codable, Equatable {
    public var type: SuggestionType
    public var title: String
    public var actionText: String
    public var confidence: Double
    public var sourceId: String
    public var threadId: String
    public var messageId: String
    public var sourceApp: String
    public var threadTitle: String
    public var evidenceSnippet: String
    public var sourceTimestamp: Date
    public var dueDate: Date?

    public init(
        type: SuggestionType,
        title: String,
        actionText: String,
        confidence: Double,
        sourceId: String,
        threadId: String,
        messageId: String,
        sourceApp: String,
        threadTitle: String,
        evidenceSnippet: String,
        sourceTimestamp: Date,
        dueDate: Date? = nil
    ) {
        self.type = type
        self.title = title
        self.actionText = actionText
        self.confidence = confidence
        self.sourceId = sourceId
        self.threadId = threadId
        self.messageId = messageId
        self.sourceApp = sourceApp
        self.threadTitle = threadTitle
        self.evidenceSnippet = evidenceSnippet
        self.sourceTimestamp = sourceTimestamp
        self.dueDate = dueDate
    }
}

public struct AuditEvent: Identifiable, Codable, Equatable {
    public var id: String
    public var eventType: String
    public var entityId: String?
    public var details: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, eventType: String, entityId: String? = nil, details: String, createdAt: Date = Date()) {
        self.id = id
        self.eventType = eventType
        self.entityId = entityId
        self.details = details
        self.createdAt = createdAt
    }
}

public struct ImportResult: Equatable {
    public var insertedSources: Int
    public var insertedThreads: Int
    public var insertedMessages: Int
    public var skippedMessages: Int

    public init(insertedSources: Int, insertedThreads: Int, insertedMessages: Int, skippedMessages: Int) {
        self.insertedSources = insertedSources
        self.insertedThreads = insertedThreads
        self.insertedMessages = insertedMessages
        self.skippedMessages = skippedMessages
    }
}
