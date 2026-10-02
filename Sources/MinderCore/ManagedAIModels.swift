import Foundation
import CryptoKit

public enum ManagedJSON {
    public static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let wholeSeconds = Date.ISO8601FormatStyle()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer(); let value = try c.decode(String.self)
            // Local history contains tens of thousands of dates. Building an ICU
            // formatter for every value stalls the main thread on each state read.
            guard let date = (try? fractional.parse(value)) ?? (try? wholeSeconds.parse(value)) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid UTC timestamp") }
            return date
        }; return d
    }
    public static func wireData<T: Encodable>(_ value: T) throws -> Data {
        // Codable omits optional keys. The wire contract explicitly encodes nullable keys.
        func normalize(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(normalize) }
            guard var object = value as? [String: Any] else { return value }
            var nullable: [String] = []
            if object["contextPass"] != nil { nullable += ["previousRecommendation"] }
            if object["scanComplete"] != nil { nullable += ["excerptStart", "excerptEnd"] }
            if object["basis"] != nil && object["headline"] != nil { nullable += ["reassessAfter"] }
            if object["action"] != nil && object["recommendationId"] != nil { nullable += ["until"] }
            if object["evidenceSummaries"] != nil { nullable += ["previousOrder"] }
            for key in nullable where object[key] == nil { object[key] = NSNull() }
            return object.mapValues(normalize)
        }
        return try JSONSerialization.data(withJSONObject: normalize(JSONSerialization.jsonObject(with: encoder().encode(value))), options: [.sortedKeys])
    }
    public static func hash<T: Encodable>(_ value: T) throws -> String { SHA256.hash(data: try encoder().encode(value)).map { String(format: "%02x", $0) }.joined() }
    public static func opaque(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func boundedBody(_ value: String) -> String {
        var result = ""; var count = 0
        for character in value { let size = String(character).utf8.count; if count + size > 2_000 { break }; result.append(character); count += size }
        return result
    }
}
public struct UserGoal: Codable, Equatable { public var text = ""; public var revision = 0; public init(text: String = "", revision: Int = 0) { self.text = text; self.revision = revision } }
public enum ReadState: String, Codable { case read, unread, unknown }
public enum ContentAvailability: String, Codable { case available, attachmentOnly, unavailable }
public enum MessageEventKind: String, Codable { case message, reaction, system, unknown }
public enum ThreadKind: String, Codable { case direct, group, unknown }
public enum ContextPass: String, Codable { case initial, expanded }
public enum AssessmentDisposition: String, Codable { case recommend, no_action, needs_context }
public enum RecommendationBasis: String, Codable { case follow_through, read_review, relationship }
public enum EvidenceConfidence: String, Codable { case low, medium, high }
public enum RecommendationUrgency: String, Codable { case routine, soon, urgent }
public struct Participant: Codable, Equatable { public var id: String; public var displayName: String; public var isLocalUser: Bool }
public struct LocalUserContext: Codable, Equatable { public var displayName: String; public var aliases: [String] }
public struct ContextMessage: Codable, Equatable, Identifiable {
    public var id: String; public var senderId: String; public var sentAt: Date; public var isFromUser: Bool
    public var body: String; public var readState: ReadState; public var eventKind: MessageEventKind
    public var contentAvailability: ContentAvailability; public var truncated: Bool
}
public struct ActivityFact: Codable, Equatable, Identifiable {
    public var id: String; public var metric: String; public var value: String; public var windowStart: Date; public var windowEnd: Date
    public var summary: String {
        let label: String
        if metric == "lastIncoming" || metric == "lastOutgoing" || metric == "lastActivity" {
            let date = ISO8601DateFormatter().date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
            label = (metric == "lastIncoming" ? "Last incoming message: " : metric == "lastOutgoing" ? "Last sent message: " : "Last exchange: ") + date
        } else if metric == "medianGapDays" { label = "Typical gap between active days: " + value + " days"
        } else if metric.hasPrefix("week") { label = value + " from " + windowStart.formatted(date: .abbreviated, time: .omitted) + " to " + windowEnd.formatted(date: .abbreviated, time: .omitted)
        } else if metric.hasPrefix("incoming") || metric.hasPrefix("outgoing") || metric.hasPrefix("activeDays") {
            let days = metric.filter(\.isNumber)
            let kind = metric.hasPrefix("incoming") ? "incoming messages" : metric.hasPrefix("outgoing") ? "sent messages" : "active days"
            label = value + " " + kind + " in the available portion of the last " + days + " days"
        } else { label = value }
        return label + " (history on this Mac)"
    }
}
public struct ContextCoverage: Codable, Equatable {
    public var scanComplete: Bool; public var observationStart: Date; public var observationEnd: Date
    public var excerptStart: Date?; public var excerptEnd: Date?; public var moreContextAvailable: Bool
}
public struct EvidenceReference: Codable, Equatable, Hashable {
    public enum Kind: String, Codable { case message, activity }
    public var kind: Kind; public var id: String
}
public struct RecommendationContent: Codable, Equatable {
    public var headline: String; public var why: String; public var nextStep: String
    public var basis: RecommendationBasis; public var confidence: EvidenceConfidence; public var urgency: RecommendationUrgency
    public var evidenceRefs: [EvidenceReference]; public var reassessAfter: Date?
}
public struct PreviousRecommendation: Codable, Equatable {
    public var id: String; public var content: RecommendationContent
}
public struct RecommendationFeedback: Codable, Equatable, Identifiable {
    public enum Action: String, Codable { case done, notUseful, snoozed, muted, undone }
    public var id: String; public var recommendationId: String; public var action: Action; public var at: Date
    public var until: Date?; public var substantiveRevision: String; public var basis: RecommendationBasis
}
public struct ThreadSnapshot: Codable, Equatable, Identifiable {
    public var threadId: String; public var snapshotId: String; public var title: String; public var kind: ThreadKind
    public var participants: [Participant]; public var messages: [ContextMessage]; public var activityFacts: [ActivityFact]
    public var coverage: ContextCoverage; public var previousRecommendation: PreviousRecommendation?
    public var feedback: [RecommendationFeedback]; public var contextPass: ContextPass
    public var id: String { threadId }
    public var substantiveRevision: String {
        if let fact = activityFacts.first(where: { $0.metric == "lastSubstantiveMessage" }) { return fact.value }
        return ManagedJSON.opaque(messages.filter { $0.eventKind == .message }.map { "\($0.id):\($0.body)" }.joined(separator: "|")) }
    public mutating func stamp() throws {
        // Snapshot identity excludes a moving clock; daily assessments handle age-based changes.
        struct StableFact: Encodable { let id: String; let metric: String; let value: String }
        struct Revision: Encodable { let messages: [ContextMessage]; let participants: [Participant]; let title: String; let complete: Bool; let facts: [StableFact] }
        snapshotId = try ManagedJSON.hash(Revision(messages: messages, participants: participants, title: title, complete: coverage.scanComplete,
            facts: activityFacts.map { StableFact(id: $0.id, metric: $0.metric, value: $0.value) }))
    }
}
public struct ContextRequest: Codable, Equatable { public var reason: String; public var totalMessages: Int }
public struct ThreadAssessment: Codable, Equatable {
    public var threadId: String; public var snapshotId: String; public var disposition: AssessmentDisposition
    public var decisionSummary: String; public var recommendation: RecommendationContent?; public var contextRequest: ContextRequest?
}
public struct AssessmentRequest: Codable {
    public var schemaVersion = 1; public var requestId = UUID().uuidString; public var runId: String
    public var observedAt: Date; public var timeZone: String; public var goal: UserGoal
    public var localUser: LocalUserContext; public var threads: [ThreadSnapshot]
}
public struct AIUsage: Codable { public var inputTokens: Int; public var outputTokens: Int; public var thinkingTokens: Int }
public struct AssessmentResponse: Codable {
    public var schemaVersion: Int; public var requestId: String; public var runId: String
    public var model: String; public var promptVersion: String; public var usage: AIUsage; public var durationMs: Int
    public var decisions: [ThreadAssessment]
}
public struct RankedRecommendation: Codable {
    public var id: String; public var content: RecommendationContent; public var evidenceSummaries: [String]
    public var lastActivityAt: Date; public var assessedAt: Date; public var previousOrder: Int?
}
public struct RankingRequest: Codable {
    public var schemaVersion = 1; public var requestId = UUID().uuidString; public var runId: String
    public var observedAt: Date; public var goal: UserGoal; public var recommendations: [RankedRecommendation]
}
public struct RankingResponse: Codable {
    public var schemaVersion: Int; public var requestId: String; public var runId: String
    public var model: String; public var promptVersion: String; public var usage: AIUsage; public var durationMs: Int
    public var orderedRecommendationIds: [String]
}
public struct ManagedAIStatus: Codable {
    public var schemaVersion: Int; public var access: Bool; public var rolloutEnabled: Bool
    public var remainingUSD: Double; public var resetsAt: Date; public var model: String
    public var assessPromptVersion: String; public var rankPromptVersion: String; public var consentVersion: Int
}
public protocol ThreadAssessmentService {
    func assess(_ request: AssessmentRequest) async throws -> AssessmentResponse
    func rank(_ request: RankingRequest) async throws -> RankingResponse
    func status() async throws -> ManagedAIStatus
}
public enum ManagedAIError: Error, LocalizedError {
    case invalidResponse, staleResult, unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalidResponse: return "AI returned incomplete or invalid results. The previous queue is retained."
        case .staleResult: return "Preferences or conversation state changed during analysis. Refresh to reassess."
        case .unavailable(let detail): return detail }
    }
}
public enum ManagedContract {
    public static func validate(_ response: AssessmentResponse, for request: AssessmentRequest) throws {
        guard response.schemaVersion == 1, response.requestId == request.requestId, response.runId == request.runId,
              response.decisions.count == request.threads.count, Set(response.decisions.map(\.threadId)).count == request.threads.count else { throw ManagedAIError.invalidResponse }
        for decision in response.decisions {
            guard let thread = request.threads.first(where: { $0.threadId == decision.threadId }), thread.snapshotId == decision.snapshotId,
                  decision.decisionSummary.count <= 240 else { throw ManagedAIError.invalidResponse }
            switch decision.disposition {
            case .recommend:
                guard let rec = decision.recommendation, decision.contextRequest == nil,
                      !rec.headline.isEmpty, rec.headline.count <= 80, !rec.why.isEmpty, rec.why.count <= 600,
                      !rec.nextStep.isEmpty, rec.nextStep.count <= 200, !rec.evidenceRefs.isEmpty,
                      Set(rec.evidenceRefs).count == rec.evidenceRefs.count,
                      rec.basis != .relationship || !request.goal.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManagedAIError.invalidResponse }
                for ref in rec.evidenceRefs {
                    guard ref.kind == .message ? thread.messages.contains(where: { $0.id == ref.id }) : thread.activityFacts.contains(where: { $0.id == ref.id && $0.metric != "lastSubstantiveMessage" }) else { throw ManagedAIError.invalidResponse }
                }
            case .no_action: guard decision.recommendation == nil, decision.contextRequest == nil else { throw ManagedAIError.invalidResponse }
            case .needs_context:
                guard decision.recommendation == nil, let context = decision.contextRequest, context.totalMessages == 80, context.reason.count <= 240 else { throw ManagedAIError.invalidResponse }
            }
        }
    }
    public static func validateOrder(_ ids: [String], expected: [String]) throws {
        guard ids.count == expected.count, Set(ids).count == ids.count, Set(ids) == Set(expected) else { throw ManagedAIError.invalidResponse }
    }
}
