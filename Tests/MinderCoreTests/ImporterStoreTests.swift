import XCTest
@testable import MinderCore

final class ImporterStoreTests: XCTestCase {
    func testSampleImportIsDuplicateSafe() throws {
        let store = try makeStore()
        let importer = ConversationImporter()

        let first = try importer.importSampleConversations(into: store)
        XCTAssertEqual(first.insertedSources, 1)
        XCTAssertEqual(first.insertedThreads, 3)
        XCTAssertEqual(first.insertedMessages, 6)
        XCTAssertEqual(first.skippedMessages, 0)

        let second = try importer.importSampleConversations(into: store)
        XCTAssertEqual(second.insertedSources, 0)
        XCTAssertEqual(second.insertedThreads, 0)
        XCTAssertEqual(second.insertedMessages, 0)
        XCTAssertEqual(second.skippedMessages, 6)

        XCTAssertEqual(try store.fetchSources().count, 1)
        XCTAssertEqual(try store.fetchThreads().count, 3)
        XCTAssertEqual(try store.fetchMessages().count, 6)
    }

    func testFetchRecentMessagesForThreadReturnsNewestWindowOldestFirst() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        let source = ConversationSource(id: "test-source", name: "Test Messages", kind: .sample, lastSyncAt: now)
        let threads = [
            ConversationThread(
                id: "thread-1",
                sourceId: source.id,
                externalId: "thread-1",
                title: "Avery",
                participantLabels: ["Avery"],
                lastMessageAt: now
            ),
            ConversationThread(
                id: "thread-2",
                sourceId: source.id,
                externalId: "thread-2",
                title: "Noah",
                participantLabels: ["Noah"],
                lastMessageAt: now
            )
        ]
        let messages = [
            testMessage(id: "one", sentAt: now.addingTimeInterval(-4 * 60 * 60), body: "One", isFromUser: false),
            testMessage(id: "two", sentAt: now.addingTimeInterval(-3 * 60 * 60), body: "Two", isFromUser: true),
            testMessage(id: "three", sentAt: now.addingTimeInterval(-2 * 60 * 60), body: "Three", isFromUser: false),
            testMessage(id: "four", sentAt: now.addingTimeInterval(-1 * 60 * 60), body: "Four", isFromUser: true),
            testMessage(id: "other", threadId: "thread-2", sentAt: now.addingTimeInterval(-30 * 60), body: "Other", isFromUser: false)
        ]

        _ = try store.saveImport(source: source, threads: threads, messages: messages)

        let recent = try store.fetchRecentMessages(threadId: "thread-1", limit: 3)

        XCTAssertEqual(recent.map(\.externalId), ["two", "three", "four"])
    }

    func testRepeatedImportUpgradesPlainTextFallbackBody() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()

        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "sent", sentAt: now, body: "[Sent reply without plain text]", isFromUser: true)
            ]
        )
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "sent", sentAt: now, body: "I brought bagels this time.", isFromUser: true)
            ]
        )

        XCTAssertEqual(try store.fetchMessages().first?.body, "I brought bagels this time.")
    }

    func testSuggestionStateTransitionsPersist() async throws {
        let store = try makeStore()
        _ = try ConversationImporter().importSampleConversations(into: store)

        let now = ISO8601DateFormatter().date(from: "2026-05-19T12:00:00Z")!
        let policy = ConversationRecommendationPolicy(now: now)
        let engine = SuggestionEngine(
            store: store,
            rankingService: LocalConversationRankingService(policy: policy),
            recommendationPolicy: policy
        )
        let generated = try await engine.generateFromStoredMessages()
        XCTAssertFalse(generated.isEmpty)

        let suggestion = try XCTUnwrap(generated.first)
        try store.updateSuggestionState(id: suggestion.id, state: .confirmed)

        let confirmed = try XCTUnwrap(try store.fetchSuggestions().first { $0.id == suggestion.id })
        XCTAssertEqual(confirmed.state, .confirmed)

        let snoozedUntil = Date(timeIntervalSince1970: 1_800_000_000)
        try store.updateSuggestionState(id: suggestion.id, state: .snoozed, snoozedUntil: snoozedUntil)

        let snoozed = try XCTUnwrap(try store.fetchSuggestions().first { $0.id == suggestion.id })
        XCTAssertEqual(snoozed.state, .snoozed)
        XCTAssertEqual(snoozed.snoozedUntil, snoozedUntil)
        XCTAssertNil(snoozed.completedAt)

        try store.updateSuggestionState(id: suggestion.id, state: .completed)
        let completed = try XCTUnwrap(try store.fetchSuggestions().first { $0.id == suggestion.id })
        XCTAssertEqual(completed.state, .completed)
        XCTAssertNotNil(completed.completedAt)

        try store.updateSuggestionState(id: suggestion.id, state: .new)
        let restored = try XCTUnwrap(try store.fetchSuggestions().first { $0.id == suggestion.id })
        XCTAssertEqual(restored.state, .new)
        XCTAssertNil(restored.completedAt)
    }

    func testGeminiRequestBuilderAndStructuredResponseParser() throws {
        let store = try makeStore()
        _ = try ConversationImporter().importSampleConversations(into: store)
        let now = ISO8601DateFormatter().date(from: "2026-05-19T12:00:00Z")!
        let context = SuggestionContext(
            sources: try store.fetchSources(),
            threads: try store.fetchThreads(),
            messages: try store.fetchMessages()
        )
        let candidates = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context)

        let builder = GeminiRequestBuilder(config: GeminiConfig(apiKey: "test-key", model: "gemini-2.5-flash"))
        let request = try builder.makeRequest(candidates: candidates, context: context)

        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(request.timeoutInterval, 12)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertNotNil(request.httpBody)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let generationConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["responseMimeType"] as? String, "application/json")
        XCTAssertEqual(generationConfig["candidateCount"] as? Int, 1)
        let responseSchema = try XCTUnwrap(generationConfig["responseSchema"] as? [String: Any])
        XCTAssertEqual(responseSchema["type"] as? String, "OBJECT")
        XCTAssertFalse(candidates.isEmpty)

        let candidate = try XCTUnwrap(candidates.first)
        let response = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "{\\"decisions\\":[{\\"shouldAlert\\":true,\\"priority\\":\\"high\\",\\"confidence\\":0.91,\\"reasonCode\\":\\"deadline_or_scheduling\\",\\"suggestionType\\":\\"deadline\\",\\"title\\":\\"Track request\\",\\"actionText\\":\\"Review the request.\\",\\"threadId\\":\\"\(candidate.threadId)\\",\\"evidenceMessageId\\":\\"\(candidate.latestMessage.id)\\",\\"evidenceSnippet\\":\\"Can you send it?\\",\\"dueDate\\":null}]}"
                  }
                ]
              }
            }
          ]
        }
        """
        let decisions = try GeminiResponseParser.parseRankingDecisions(from: Data(response.utf8), candidates: candidates, context: context)

        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.suggestionType, .deadline)
        XCTAssertEqual(decisions.first?.priority, .high)
        XCTAssertEqual(decisions.first?.threadId, candidate.threadId)
    }

    func testGeminiParserExtractsJSONFromProseOrCodeFence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
        ])
        let candidates = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context)
        let candidate = try XCTUnwrap(candidates.first)
        let json = """
        {"decisions":[{"shouldAlert":true,"priority":"medium","confidence":0.82,"reasonCode":"direct_action_request","suggestionType":"unansweredQuestion","title":"Reply","actionText":"Reply.","threadId":"\(candidate.threadId)","evidenceMessageId":"\(candidate.latestMessage.id)","evidenceSnippet":"Can you send the notes?"}]}
        """

        let prose = try GeminiResponseParser.parseRankingDecisions(
            from: try geminiResponseData(text: "Here is the JSON:\n\(json)\nThanks."),
            candidates: candidates,
            context: context
        )
        let fenced = try GeminiResponseParser.parseRankingDecisions(
            from: try geminiResponseData(text: "```json\n\(json)\n```"),
            candidates: candidates,
            context: context
        )

        XCTAssertEqual(prose.count, 1)
        XCTAssertEqual(fenced.count, 1)
    }

    func testGeminiGeneratorSendsExpectedMockRequestAndReceivesStructuredResponse() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "old-excluded", sentAt: now.addingTimeInterval(-14 * 60 * 60), body: "Old unrelated body that should never be sent", isFromUser: false),
            testMessage(id: "context-1", sentAt: now.addingTimeInterval(-13 * 60 * 60), body: "Context one", isFromUser: false),
            testMessage(id: "context-2", sentAt: now.addingTimeInterval(-12 * 60 * 60), body: "Context two", isFromUser: false),
            testMessage(id: "context-3", sentAt: now.addingTimeInterval(-11 * 60 * 60), body: "Context three", isFromUser: false),
            testMessage(id: "context-4", sentAt: now.addingTimeInterval(-10 * 60 * 60), body: "Context four", isFromUser: false),
            testMessage(id: "context-5", sentAt: now.addingTimeInterval(-9 * 60 * 60), body: "Context five", isFromUser: false),
            testMessage(id: "inbound-ask", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
        ])
        let candidates = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGeminiURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockGeminiURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            let body = try XCTUnwrap(requestBodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
            let firstContent = try XCTUnwrap(contents.first)
            let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])
            let prompt = try XCTUnwrap(parts.first?["text"] as? String)
            XCTAssertTrue(prompt.contains("Conversation ranking payload as JSON"))
            XCTAssertTrue(prompt.contains("localUser"))
            XCTAssertTrue(prompt.contains("message-test-source-inbound-ask"))
            XCTAssertFalse(prompt.contains("Old unrelated body that should never be sent"))

            let response = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "text": "{\\"decisions\\":[{\\"shouldAlert\\":true,\\"priority\\":\\"medium\\",\\"confidence\\":0.86,\\"reasonCode\\":\\"direct_action_request\\",\\"suggestionType\\":\\"unansweredQuestion\\",\\"title\\":\\"Reply to Avery\\",\\"actionText\\":\\"Send the notes.\\",\\"threadId\\":\\"thread-1\\",\\"evidenceMessageId\\":\\"message-test-source-inbound-ask\\",\\"evidenceSnippet\\":\\"Can you send the notes?\\",\\"dueDate\\":null}]}"
                      }
                    ]
                  }
                }
              ]
            }
            """
            let httpResponse = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (httpResponse, Data(response.utf8))
        }
        defer { MockGeminiURLProtocol.requestHandler = nil }

        let decisions = try await GeminiConversationRankingService(
            config: GeminiConfig(apiKey: "test-key", model: "gemini-2.5-flash"),
            session: session
        ).rankCandidates(candidates, context: context)

        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.threadId, "thread-1")
        XCTAssertEqual(decisions.first?.evidenceMessageId, "message-test-source-inbound-ask")
        XCTAssertEqual(decisions.first?.suggestionType, .unansweredQuestion)
    }

    func testGeminiConfigCanLoadFromDotenvFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dotenvURL = directory.appendingPathComponent(".env")
        try """
        GEMINI_API_KEY=test-dotenv-key
        GEMINI_MODEL=gemini-2.5-flash
        """.write(to: dotenvURL, atomically: true, encoding: .utf8)

        let config = try XCTUnwrap(GeminiConfig.fromEnvironment([:], dotenvURLs: [dotenvURL]))

        XCTAssertEqual(config.apiKey, "test-dotenv-key")
        XCTAssertEqual(config.model, "gemini-2.5-flash")
    }

    func testGeminiConfigStoreSavesLocalConfigAndPreservesOtherValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent(".nudge.env")
        try """
        OTHER_VALUE=keep-me
        GEMINI_API_KEY=old-key
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = GeminiConfigStore(url: configURL)
        try store.save(GeminiConfig(apiKey: "new-gemini-key", model: "gemini-2.5-flash"))

        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("OTHER_VALUE=keep-me"))
        XCTAssertTrue(contents.contains("GEMINI_API_KEY=new-gemini-key"))
        XCTAssertTrue(contents.contains("GEMINI_MODEL=gemini-2.5-flash"))
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("refresh_token"))

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.apiKey, "new-gemini-key")
        XCTAssertEqual(saved.model, "gemini-2.5-flash")
    }

    func testGeminiConfigValidationRejectsMissingAndPlaceholderKeys() {
        XCTAssertEqual(GeminiConfigValidationResult.validate(nil), .missingAPIKey)
        XCTAssertEqual(
            GeminiConfigValidationResult.validate(GeminiConfig(apiKey: "your-gemini-api-key-here")),
            .placeholderAPIKey
        )

        let valid = GeminiConfigValidationResult.validate(GeminiConfig(apiKey: "real-looking-key", model: "gemini-2.5-flash"))
        XCTAssertEqual(valid.config?.apiKey, "real-looking-key")
        XCTAssertTrue(valid.isValid)
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    func testGeminiDiagnosticRunSaveFetchAndClearKeepsOtherData() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveUserProfile(UserProfile(displayName: "Kainoa", completedOnboardingAt: now))
        try store.upsertPermissionHealth(PermissionHealth(kind: .cloudAI, state: .available, detail: "Gemini enabled."))
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        _ = try store.upsertSuggestions([
            testDraft(
                type: .unansweredQuestion,
                confidence: 0.84,
                messageId: "message-test-source-ask",
                sourceTimestamp: now.addingTimeInterval(-8 * 60 * 60)
            )
        ])

        let run = GeminiDiagnosticRun(
            model: "gemini-2.5-flash",
            createdAt: now,
            durationMilliseconds: 321,
            outcome: .failure,
            errorCategory: .http,
            fallbackUsed: true,
            httpStatus: 400,
            candidateCount: 2,
            decisionCount: 0,
            rankedCount: 1,
            savedCount: 1,
            candidateThreadIds: ["thread-1"],
            candidateMessageIds: ["message-test-source-ask"],
            detail: "Gemini returned HTTP 400."
        )
        try store.saveGeminiDiagnosticRun(run)

        let fetched = try XCTUnwrap(try store.fetchGeminiDiagnosticRuns(limit: 10).first)
        XCTAssertEqual(fetched.model, "gemini-2.5-flash")
        XCTAssertEqual(fetched.durationMilliseconds, 321)
        XCTAssertEqual(fetched.outcome, .failure)
        XCTAssertEqual(fetched.errorCategory, .http)
        XCTAssertTrue(fetched.fallbackUsed)
        XCTAssertEqual(fetched.httpStatus, 400)
        XCTAssertEqual(fetched.candidateCount, 2)
        XCTAssertEqual(fetched.rankedCount, 1)
        XCTAssertEqual(fetched.candidateThreadIds, ["thread-1"])
        XCTAssertEqual(fetched.candidateMessageIds, ["message-test-source-ask"])

        try store.clearGeminiDiagnosticRuns()

        XCTAssertTrue(try store.fetchGeminiDiagnosticRuns().isEmpty)
        XCTAssertEqual(try store.fetchMessages().count, 1)
        XCTAssertEqual(try store.fetchSuggestions().count, 1)
        XCTAssertEqual(try store.fetchUserProfile()?.displayName, "Kainoa")
        XCTAssertEqual(try store.fetchPermissionHealth(kind: .cloudAI)?.state, .available)
    }

    func testGeminiDiagnosticRunDoesNotStoreMessageBodies() throws {
        let store = try makeStore()
        let privateBody = "Private body that must not appear in diagnostics"
        let run = GeminiDiagnosticRun(
            model: "gemini-2.5-flash",
            durationMilliseconds: 20,
            outcome: .success,
            errorCategory: .success,
            fallbackUsed: false,
            candidateCount: 1,
            decisionCount: 1,
            rankedCount: 1,
            savedCount: 1,
            candidateThreadIds: ["thread-1"],
            candidateMessageIds: ["message-test-source-secret-message"],
            detail: "Gemini ranked candidate threads successfully."
        )

        try store.saveGeminiDiagnosticRun(run)
        let fetched = try XCTUnwrap(try store.fetchGeminiDiagnosticRuns().first)
        let diagnosticText = [
            fetched.model,
            fetched.outcome.rawValue,
            fetched.errorCategory.rawValue,
            fetched.candidateThreadIds.joined(separator: " "),
            fetched.candidateMessageIds.joined(separator: " "),
            fetched.detail
        ].joined(separator: " ")

        XCTAssertFalse(diagnosticText.contains(privateBody))
        XCTAssertFalse(diagnosticText.contains("Private body"))
    }
#endif

    func testGeminiHTTPFailureExposesStatusCode() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
        ])
        let candidates = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGeminiURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockGeminiURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data(#"{"error":{"message":"bad request"}}"#.utf8))
        }
        defer { MockGeminiURLProtocol.requestHandler = nil }

        do {
            _ = try await GeminiConversationRankingService(
                config: GeminiConfig(apiKey: "test-key"),
                session: session
            ).rankCandidatesWithMetadata(candidates, context: context)
            XCTFail("Expected Gemini HTTP failure.")
        } catch let error as GeminiError {
            XCTAssertEqual(error.httpStatus, 400)
            guard case .requestFailed(let statusCode, _) = error else {
                return XCTFail("Expected requestFailed, got \(error).")
            }
            XCTAssertEqual(statusCode, 400)
        }
    }

    func testGeminiParserReportsMissingOutputInvalidJSONAndInvalidEvidence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
        ])
        let candidates = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context)
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertThrowsError(try GeminiResponseParser.parseRankingDecisions(
            from: Data(#"{"candidates":[{"content":{"parts":[{}]}}]}"#.utf8),
            candidates: candidates,
            context: context
        )) { error in
            guard case GeminiError.missingOutputText = error else {
                return XCTFail("Expected missingOutputText, got \(error).")
            }
        }

        XCTAssertThrowsError(try GeminiResponseParser.parseRankingDecisions(
            from: try geminiResponseData(text: "not valid json"),
            candidates: candidates,
            context: context
        )) { error in
            guard case GeminiError.invalidJSON = error else {
                return XCTFail("Expected invalidJSON, got \(error).")
            }
        }

        let invalidEvidence = """
        {"decisions":[{"shouldAlert":true,"priority":"high","confidence":0.90,"reasonCode":"direct_action_request","suggestionType":"unansweredQuestion","title":"Reply","actionText":"Reply.","threadId":"\(candidate.threadId)","evidenceMessageId":"missing-message","evidenceSnippet":"Can you send the notes?","dueDate":null}]}
        """
        XCTAssertThrowsError(try GeminiResponseParser.parseRankingDecisions(
            from: try geminiResponseData(text: invalidEvidence),
            candidates: candidates,
            context: context
        )) { error in
            guard case GeminiError.invalidEvidenceReference(let id, _) = error else {
                return XCTFail("Expected invalidEvidenceReference, got \(error).")
            }
            XCTAssertEqual(id, "missing-message")
        }
    }

    func testUserProfileSaveUpdateAndCompletionPersist() throws {
        let store = try makeStore()
        var profile = UserProfile(
            displayName: "Kainoa",
            timeZoneIdentifier: "America/Los_Angeles",
            notificationCadence: .dailyDigest,
            quietHoursStartMinutes: 21 * 60,
            quietHoursEndMinutes: 8 * 60,
            sourcePriority: [.appleMessages, .sample],
            cloudAIEnabled: false,
            appColorScheme: .forest
        )

        try store.saveUserProfile(profile)
        let saved = try XCTUnwrap(try store.fetchUserProfile())
        XCTAssertEqual(saved.displayName, "Kainoa")
        XCTAssertEqual(saved.notificationCadence, .dailyDigest)
        XCTAssertEqual(saved.sourcePriority, [.appleMessages, .sample])
        XCTAssertEqual(saved.appColorScheme, .forest)
        XCTAssertFalse(saved.hasCompletedOnboarding)
        XCTAssertFalse(try store.hasCompletedOnboarding())

        profile.cloudAIEnabled = true
        profile.appColorScheme = .plum
        profile.completedOnboardingAt = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveUserProfile(profile)

        let completed = try XCTUnwrap(try store.fetchUserProfile())
        XCTAssertTrue(completed.cloudAIEnabled)
        XCTAssertEqual(completed.appColorScheme, .plum)
        XCTAssertTrue(completed.hasCompletedOnboarding)
        XCTAssertTrue(try store.hasCompletedOnboarding())
    }

    func testUserProfileMigrationDefaultsAppColorScheme() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        let now = DateCoding.iso8601.string(from: Date(timeIntervalSince1970: 1_800_000_000))
        try database.execute(
            """
            CREATE TABLE user_profiles (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                time_zone_identifier TEXT NOT NULL,
                notification_cadence TEXT NOT NULL,
                quiet_hours_start_minutes INTEGER NOT NULL,
                quiet_hours_end_minutes INTEGER NOT NULL,
                source_priority TEXT NOT NULL,
                cloud_ai_enabled INTEGER NOT NULL,
                completed_onboarding_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        try database.execute(
            """
            INSERT INTO user_profiles (
                id, display_name, time_zone_identifier, notification_cadence,
                quiet_hours_start_minutes, quiet_hours_end_minutes, source_priority,
                cloud_ai_enabled, completed_onboarding_at, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(UserProfile.defaultID),
                .text("Kainoa"),
                .text("America/Los_Angeles"),
                .text(NotificationCadence.hourlyDigest.rawValue),
                .int(22 * 60),
                .int(7 * 60),
                .text("[\"appleMessages\",\"sample\"]"),
                .int(0),
                .null,
                .text(now),
                .text(now)
            ]
        )

        let store = try MinderStore(databaseURL: databaseURL)
        let migrated = try XCTUnwrap(try store.fetchUserProfile())
        XCTAssertEqual(migrated.appColorScheme, .ocean)
    }

    func testSuggestionMigrationBackfillsCompletedAtForLegacyCompletedRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        let completedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let activeUpdatedAt = completedAt.addingTimeInterval(-60)

        try database.execute(
            """
            CREATE TABLE suggestions (
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
                snoozed_until TEXT
            )
            """
        )
        try insertLegacySuggestion(database, id: "legacy-completed", state: .completed, updatedAt: completedAt)
        try insertLegacySuggestion(database, id: "legacy-active", state: .new, updatedAt: activeUpdatedAt)

        let store = try MinderStore(databaseURL: databaseURL)
        let suggestions = try store.fetchSuggestions()

        XCTAssertEqual(suggestions.first { $0.id == "legacy-completed" }?.completedAt, completedAt)
        XCTAssertNil(suggestions.first { $0.id == "legacy-active" }?.completedAt)
    }

    func testPermissionHealthUpsertAndTransitionsPersist() throws {
        let store = try makeStore()
        let missing = PermissionHealth(
            kind: .notifications,
            state: .missing,
            detail: "Notifications have not been requested yet.",
            lastCheckedAt: Date(timeIntervalSince1970: 10)
        )
        let available = PermissionHealth(
            kind: .notifications,
            state: .available,
            detail: "Notifications are enabled.",
            lastCheckedAt: Date(timeIntervalSince1970: 20)
        )

        try store.upsertPermissionHealth(missing)
        XCTAssertEqual(try store.fetchPermissionHealth(kind: .notifications)?.state, .missing)

        try store.upsertPermissionHealth(available)
        let fetched = try XCTUnwrap(try store.fetchPermissionHealth(kind: .notifications))
        XCTAssertEqual(fetched.state, .available)
        XCTAssertEqual(fetched.detail, "Notifications are enabled.")
        XCTAssertEqual(try store.fetchPermissionHealth().count, 1)
    }

    func testUnrepliedInboundCreatesOneRecommendationWithoutDelay() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "inbound-ask", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)
        let ranked = pipeline.drafts

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.type, .unansweredQuestion)
    }

    func testYoungNormalInboundCreatesLooseFollowUpRecommendation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "inbound-normal", sentAt: now.addingTimeInterval(-60), body: "I was thinking about the trip", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(pipeline.drafts.count, 1)
    }

    func testOlderNormalInboundCreatesLowPriorityFollowUpCandidate() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "inbound-normal", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "I looked at the trip plan and have a few thoughts.", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(pipeline.candidates.first?.reasonHints, ["unrepliedInbound"])
        XCTAssertEqual(pipeline.drafts.count, 1)
        XCTAssertEqual(pipeline.drafts.first?.type, .followUpNudge)
        XCTAssertEqual(pipeline.drafts.first?.confidence, 0.51)
    }

    func testUserReplyAfterInboundCreatesLowPriorityReviewSuggestion() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "inbound-ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false),
            testMessage(id: "user-reply", sentAt: now.addingTimeInterval(-1 * 60 * 60), body: "Sending them now.", isFromUser: true)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(pipeline.candidates.first?.reasonHints, ["repliedThread"])
        XCTAssertEqual(pipeline.drafts.count, 1)
        XCTAssertEqual(pipeline.drafts.first?.type, .followUpNudge)
        XCTAssertEqual(pipeline.drafts.first?.confidence, 0.16)
        XCTAssertEqual(pipeline.drafts.first?.messageId, "message-test-source-user-reply")
    }

    func testRepliedClosureOnlyThreadIsIgnored() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "inbound-ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false),
            testMessage(id: "user-reply", sentAt: now.addingTimeInterval(-1 * 60 * 60), body: "Done", isFromUser: true)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertTrue(pipeline.candidates.isEmpty)
        XCTAssertTrue(pipeline.drafts.isEmpty)
    }

    func testCloudDraftBeforeUserReplyIsSuppressedByPolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inbound = testMessage(id: "inbound-ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
        let context = makeSuggestionContext(messages: [
            inbound,
            testMessage(id: "user-reply", sentAt: now.addingTimeInterval(-1 * 60 * 60), body: "Sent them.", isFromUser: true)
        ])
        let candidate = testCandidate(context: context, latestMessage: inbound)
        let staleDecision = ConversationRankingDecision(
            shouldAlert: true,
            priority: .high,
            confidence: 0.95,
            reasonCode: "stale_cloud_decision",
            suggestionType: .staleReply,
            title: "Reply to Avery",
            actionText: "Open the conversation.",
            threadId: "thread-1",
            evidenceMessageId: inbound.id,
            evidenceSnippet: inbound.body
        )

        let ranked = ConversationRecommendationPolicy(now: now).rankedDrafts([staleDecision], candidates: [candidate], context: context)

        XCTAssertTrue(ranked.isEmpty)
    }

    func testQuestionAddressedToOtherPersonCanCreateLooseFollowUp() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = UserProfile(displayName: "Kainoa Nishida")
        let context = makeSuggestionContext(
            messages: [
                testMessage(id: "colton-question", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "Colton, how was your interview?", isFromUser: false)
            ],
            userProfile: profile
        )

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(pipeline.drafts.count, 1)
        XCTAssertEqual(pipeline.drafts.first?.type, .unansweredQuestion)
    }

    func testQuestionAddressedToKaiAliasCanAlert() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = UserProfile(displayName: "Kainoa Nishida")
        let context = makeSuggestionContext(
            messages: [
                testMessage(id: "kai-question", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "Kai, can you send the notes?", isFromUser: false)
            ],
            userProfile: profile
        )

        let pipeline = try await localRankingPipeline(context: context, now: now)
        let ranked = pipeline.drafts

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.type, .unansweredQuestion)
    }

    func testSocialGroupCommentaryCanCreateLooseFollowUpCandidate() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(
            messages: [
                testMessage(
                    id: "social-commentary",
                    sentAt: now.addingTimeInterval(-7 * 60 * 60),
                    body: #"Nice house Kim and Mark!!🤞 Andy and Rita, your trip looks amazing!! The water is so blue. I'd love a trip like that where I could "RELAX"! 😜"#,
                    isFromUser: false
                )
            ],
            userProfile: UserProfile(displayName: "Kainoa Nishida")
        )

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(pipeline.drafts.count, 1)
    }

    func testEmbeddedAddresseeToOtherPeopleCanCreateLooseFollowUp() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(
            messages: [
                testMessage(id: "embedded-addressee", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "That looks fun. Andy and Rita, can you send photos?", isFromUser: false)
            ],
            userProfile: UserProfile(displayName: "Kainoa Nishida")
        )

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(pipeline.drafts.count, 1)
        XCTAssertEqual(pipeline.drafts.first?.type, .unansweredQuestion)
    }

    func testClosureOnlyInboundIsIgnored() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "thanks", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Thanks!", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertTrue(pipeline.candidates.isEmpty)
        XCTAssertTrue(pipeline.drafts.isEmpty)
    }

    func testUrgentInboundCanAlertWithoutQuietBuffer() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "urgent", sentAt: now.addingTimeInterval(-45 * 60), body: "Can you send the deck by Friday at noon?", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)
        let ranked = pipeline.drafts

        XCTAssertEqual(pipeline.candidates.count, 1)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.type, .deadline)
    }

    func testInboundOlderThanMaximumAlertAgeIsIgnored() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "old-ask", sentAt: now.addingTimeInterval(-31 * 86_400), body: "Can you send the notes?", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertTrue(pipeline.candidates.isEmpty)
        XCTAssertTrue(pipeline.drafts.isEmpty)
    }

    func testAprilStyleMessagesAreIgnoredWhenNowIsInMay() async throws {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-05-19T12:00:00Z")!
        let aprilMessage = formatter.date(from: "2026-04-10T12:00:00Z")!
        let context = makeSuggestionContext(messages: [
            testMessage(id: "april", sentAt: aprilMessage, body: "Can you send the notes?", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)

        XCTAssertTrue(pipeline.candidates.isEmpty)
        XCTAssertTrue(pipeline.drafts.isEmpty)
    }

    func testRankedAlertsPreferRecentHighQualityThreads() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-6 * 86_400)
        let recent = now.addingTimeInterval(-2 * 86_400)
        let context = SuggestionContext(
            sources: [ConversationSource(id: "test-source", name: "Test Messages", kind: .sample)],
            threads: [
                ConversationThread(id: "thread-old", sourceId: "test-source", externalId: "thread-old", title: "Old", participantLabels: ["Old"], lastMessageAt: old),
                ConversationThread(id: "thread-recent", sourceId: "test-source", externalId: "thread-recent", title: "Recent", participantLabels: ["Recent"], lastMessageAt: recent)
            ],
            messages: [
                testMessage(id: "old", threadId: "thread-old", sentAt: old, body: "Can you send the notes?", isFromUser: false),
                testMessage(id: "recent", threadId: "thread-recent", sentAt: recent, body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let candidates = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context)
        let decisions = candidates.map { candidate in
            ConversationRankingDecision(
                shouldAlert: true,
                priority: .medium,
                confidence: 0.84,
                reasonCode: "direct_action_request",
                suggestionType: .unansweredQuestion,
                title: "Review \(candidate.threadTitle)",
                actionText: "Open the conversation.",
                threadId: candidate.threadId,
                evidenceMessageId: candidate.latestMessage.id,
                evidenceSnippet: candidate.latestMessage.body
            )
        }

        let ranked = ConversationRecommendationPolicy(now: now).rankedDrafts(decisions, candidates: candidates, context: context)

        XCTAssertEqual(ranked.map(\.threadId), ["thread-recent", "thread-old"])
    }

    func testMultipleCandidatesInOneThreadCollapseToHighestRankedDraft() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "promise", sentAt: now.addingTimeInterval(-2 * 60 * 60), body: "I can send the deck tomorrow.", isFromUser: true),
            testMessage(id: "urgent", sentAt: now.addingTimeInterval(-45 * 60), body: "Can you send the deck by Friday at noon?", isFromUser: false)
        ])

        let pipeline = try await localRankingPipeline(context: context, now: now)
        let ranked = pipeline.drafts

        XCTAssertEqual(pipeline.candidates.filter { $0.threadId == "thread-1" }.count, 1)
        XCTAssertEqual(pipeline.decisions.filter { $0.threadId == "thread-1" }.count, 1)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.type, .deadline)
    }

    func testCloudAIDecisionsAreFilteredToOnePerThreadAndVeryLowConfidenceIsSuppressed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "urgent", sentAt: now.addingTimeInterval(-45 * 60), body: "Can you send the deck by Friday at noon?", isFromUser: false)
        ])
        let candidate = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context).first!
        let low = ConversationRankingDecision(
            shouldAlert: true,
            priority: .low,
            confidence: 0.34,
            reasonCode: "too_uncertain",
            suggestionType: .deadline,
            title: "Low",
            actionText: "Low",
            threadId: candidate.threadId,
            evidenceMessageId: candidate.latestMessage.id,
            evidenceSnippet: candidate.latestMessage.body
        )
        let question = ConversationRankingDecision(
            shouldAlert: true,
            priority: .medium,
            confidence: 0.95,
            reasonCode: "question",
            suggestionType: .unansweredQuestion,
            title: "Question",
            actionText: "Question",
            threadId: candidate.threadId,
            evidenceMessageId: candidate.latestMessage.id,
            evidenceSnippet: candidate.latestMessage.body
        )
        let deadline = ConversationRankingDecision(
            shouldAlert: true,
            priority: .high,
            confidence: 0.80,
            reasonCode: "deadline",
            suggestionType: .deadline,
            title: "Deadline",
            actionText: "Deadline",
            threadId: candidate.threadId,
            evidenceMessageId: candidate.latestMessage.id,
            evidenceSnippet: candidate.latestMessage.body
        )

        let ranked = ConversationRecommendationPolicy(now: now).rankedDrafts([low, question, deadline], candidates: [candidate], context: context)

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.type, .deadline)
        XCTAssertEqual(ranked.first?.confidence, 0.85)
    }

    func testGeminiShouldAlertFalseCreatesNoSuggestion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "question", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
        ])
        let candidate = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context).first!
        let decision = ConversationRankingDecision(
            shouldAlert: false,
            priority: .low,
            confidence: 0.90,
            reasonCode: "not_actionable",
            suggestionType: .unansweredQuestion,
            title: "",
            actionText: "",
            threadId: candidate.threadId,
            evidenceMessageId: candidate.latestMessage.id,
            evidenceSnippet: candidate.latestMessage.body
        )

        let ranked = ConversationRecommendationPolicy(now: now).rankedDrafts([decision], candidates: [candidate], context: context)

        XCTAssertTrue(ranked.isEmpty)
    }

    func testLowPriorityPlausibleDecisionCreatesLowConfidenceSuggestion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeSuggestionContext(messages: [
            testMessage(id: "question", sentAt: now.addingTimeInterval(-7 * 60 * 60), body: "Do you know where the notes are?", isFromUser: false)
        ])
        let candidate = ConversationCandidateBuilder(policy: ConversationRecommendationPolicy(now: now)).candidates(from: context).first!
        let decision = ConversationRankingDecision(
            shouldAlert: true,
            priority: .low,
            confidence: 0.36,
            reasonCode: "possible_question",
            suggestionType: .unansweredQuestion,
            title: "Maybe reply to Avery",
            actionText: "Check whether this needs your response.",
            threadId: candidate.threadId,
            evidenceMessageId: candidate.latestMessage.id,
            evidenceSnippet: candidate.latestMessage.body
        )

        let ranked = ConversationRecommendationPolicy(now: now).rankedDrafts([decision], candidates: [candidate], context: context)

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.confidence, 0.36)
        XCTAssertEqual(ranked.first?.type, .unansweredQuestion)
    }

    func testStorePersistsLooseConfidenceSuggestionAtFifteenPercent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "loose", sentAt: now.addingTimeInterval(-60), body: "Thinking about this.", isFromUser: false)
            ]
        )

        _ = try store.upsertSuggestions([
                testDraft(
                    type: .followUpNudge,
                    confidence: 0.15,
                    messageId: "message-test-source-loose",
                    sourceTimestamp: now.addingTimeInterval(-60)
                )
            ])

        let saved = try XCTUnwrap(try store.fetchSuggestions().first)
        XCTAssertEqual(saved.confidence, 0.15)
        XCTAssertEqual(saved.confidenceLabel, "Low")
    }

    func testRepeatedGenerationRefreshesSingleActiveThreadAlert() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "first-ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let policy = ConversationRecommendationPolicy(now: now)
        let engine = SuggestionEngine(store: store, rankingService: LocalConversationRankingService(policy: policy), recommendationPolicy: policy)

        _ = try await engine.generateFromStoredMessages()
        XCTAssertEqual(try store.fetchSuggestions().count, 1)

        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "first-ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false),
                testMessage(id: "new-urgent", sentAt: now.addingTimeInterval(-45 * 60), body: "Actually, can you send the notes by Friday?", isFromUser: false)
            ]
        )

        _ = try await engine.generateFromStoredMessages()
        let suggestions = try store.fetchSuggestions()

        XCTAssertEqual(suggestions.count, 2)
        let activeSuggestions = try store.fetchSuggestions(includeCompleted: false)
        XCTAssertEqual(activeSuggestions.count, 1)
        XCTAssertEqual(activeSuggestions.first?.type, .deadline)
        XCTAssertEqual(activeSuggestions.first?.evidence.messageId, "message-test-source-new-urgent")
        XCTAssertEqual(suggestions.first { $0.evidence.messageId == "message-test-source-first-ask" }?.state, .superseded)
    }

    func testNormalGenerationPreservesCompletedSuggestionState() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let policy = ConversationRecommendationPolicy(now: now)
        let engine = SuggestionEngine(
            store: store,
            rankingService: LocalConversationRankingService(policy: policy),
            recommendationPolicy: policy
        )

        let first = try await engine.generateReportFromStoredMessages()
        let suggestion = try XCTUnwrap(first.savedSuggestions.first)
        try store.updateSuggestionState(id: suggestion.id, state: .completed)
        let completedAt = try XCTUnwrap(try store.fetchSuggestions().first { $0.id == suggestion.id }?.completedAt)

        let second = try await engine.generateReportFromStoredMessages()
        let saved = try XCTUnwrap(try store.fetchSuggestions().first { $0.id == suggestion.id })

        XCTAssertEqual(saved.state, .completed)
        XCTAssertEqual(saved.completedAt, completedAt)
        XCTAssertEqual(second.savedSuggestions.first?.state, .completed)
        XCTAssertEqual(second.savedSuggestions.first?.completedAt, completedAt)
        XCTAssertEqual(second.activeSavedCount, 0)
    }

    func testNewEvidenceInCompletedThreadCreatesNewActiveSuggestion() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        let firstDraft = testDraft(
            type: .unansweredQuestion,
            confidence: 0.84,
            messageId: "message-test-source-first-ask",
            sourceTimestamp: now.addingTimeInterval(-8 * 60 * 60)
        )
        let firstSuggestion = try XCTUnwrap(try store.upsertSuggestions([firstDraft]).first)
        try store.updateSuggestionState(id: firstSuggestion.id, state: .completed)

        let secondDraft = testDraft(
            type: .unansweredQuestion,
            confidence: 0.88,
            messageId: "message-test-source-second-ask",
            sourceTimestamp: now.addingTimeInterval(-30 * 60)
        )
        _ = try store.upsertSuggestions([secondDraft])

        let suggestions = try store.fetchSuggestions()
        let activeSuggestions = try store.fetchSuggestions(includeCompleted: false)

        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first { $0.evidence.messageId == firstDraft.messageId }?.state, .completed)
        XCTAssertEqual(activeSuggestions.count, 1)
        XCTAssertEqual(activeSuggestions.first?.evidence.messageId, secondDraft.messageId)
        XCTAssertEqual(activeSuggestions.first?.state, .new)
    }

    func testLegacyCompletedSuggestionWithSameEvidenceDoesNotResurface() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let store = try MinderStore(databaseURL: databaseURL)
        let database = try SQLiteDatabase(url: databaseURL)
        let draft = testDraft(
            type: .staleReply,
            confidence: 0.80,
            messageId: "legacy-message",
            sourceTimestamp: now.addingTimeInterval(-60)
        )
        try insertLegacySuggestion(
            database,
            id: legacySuggestionID(sourceId: draft.sourceId, threadId: draft.threadId),
            state: .completed,
            updatedAt: now,
            type: draft.type,
            messageId: draft.messageId
        )

        let saved = try XCTUnwrap(try store.upsertSuggestions([draft]).first)

        XCTAssertEqual(saved.state, .completed)
        XCTAssertEqual(saved.id, legacySuggestionID(sourceId: draft.sourceId, threadId: draft.threadId))
        XCTAssertEqual(try store.fetchSuggestions(includeCompleted: false).count, 0)
        XCTAssertEqual(try store.fetchSuggestions(includeCompleted: true).count, 1)
    }

    func testManualQueueItemLifecyclePersistsCompletionUndoAndDelete() throws {
        let store = try makeStore()

        let item = try store.createManualQueueItem(kind: .todo, title: "  Send invoice  ", body: "  Check the latest amount.  ")
        var saved = try XCTUnwrap(try store.fetchManualQueueItems().first)

        XCTAssertEqual(saved.id, item.id)
        XCTAssertEqual(saved.kind, .todo)
        XCTAssertEqual(saved.title, "Send invoice")
        XCTAssertEqual(saved.body, "Check the latest amount.")
        XCTAssertEqual(saved.state, .active)
        XCTAssertNil(saved.completedAt)

        try store.updateManualQueueItemState(id: item.id, state: .completed)
        saved = try XCTUnwrap(try store.fetchManualQueueItems().first)
        XCTAssertEqual(saved.state, .completed)
        XCTAssertNotNil(saved.completedAt)
        XCTAssertTrue(try store.fetchManualQueueItems(includeCompleted: false).isEmpty)

        try store.updateManualQueueItemState(id: item.id, state: .active)
        saved = try XCTUnwrap(try store.fetchManualQueueItems(includeCompleted: false).first)
        XCTAssertEqual(saved.state, .active)
        XCTAssertNil(saved.completedAt)

        try store.deleteManualQueueItem(id: item.id)
        XCTAssertTrue(try store.fetchManualQueueItems().isEmpty)
    }

    func testManualQueueItemMigrationRepairsLegacyNoteTable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")

        do {
            let database = try SQLiteDatabase(url: databaseURL)
            try database.execute(
                """
                CREATE TABLE manual_queue_items (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL
                )
                """
            )
            try database.execute(
                "INSERT INTO manual_queue_items (id, kind, title) VALUES (?, ?, ?)",
                [.text("legacy-note"), .text("Note"), .text("  Legacy note  ")]
            )
        }

        let store = try MinderStore(databaseURL: databaseURL)
        let legacyItem = try XCTUnwrap(try store.fetchManualQueueItems().first { $0.id == "legacy-note" })

        XCTAssertEqual(legacyItem.kind, .note)
        XCTAssertEqual(legacyItem.title, "Legacy note")
        XCTAssertEqual(legacyItem.state, .active)
        XCTAssertNil(legacyItem.body)

        let newNote = try store.createManualQueueItem(kind: .note, title: "  Fresh note  ", body: "  Keep it stable.  ")
        let savedNote = try XCTUnwrap(try store.fetchManualQueueItems().first { $0.id == newNote.id })

        XCTAssertEqual(savedNote.kind, .note)
        XCTAssertEqual(savedNote.title, "Fresh note")
        XCTAssertEqual(savedNote.body, "Keep it stable.")
    }

    func testNormalGenerationPreservesManualQueueItems() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        let manualItem = try store.createManualQueueItem(kind: .note, title: "Ask Maya about lunch")
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )

        let policy = ConversationRecommendationPolicy(now: now)
        _ = try await SuggestionEngine(
            store: store,
            rankingService: LocalConversationRankingService(policy: policy),
            recommendationPolicy: policy
        ).generateFromStoredMessages()

        let savedManualItem = try XCTUnwrap(try store.fetchManualQueueItems().first)
        XCTAssertEqual(savedManualItem.id, manualItem.id)
        XCTAssertEqual(savedManualItem.title, "Ask Maya about lunch")
        XCTAssertEqual(savedManualItem.state, .active)
        XCTAssertEqual(try store.fetchSuggestions(includeCompleted: false).count, 1)
    }

    func testGenerationRefreshesActiveAlertWhenUserHasResponded() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "first-ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let engine = SuggestionEngine(
            store: store,
            rankingService: LocalConversationRankingService(policy: ConversationRecommendationPolicy(now: now)),
            recommendationPolicy: ConversationRecommendationPolicy(now: now)
        )

        _ = try await engine.generateFromStoredMessages()
        XCTAssertEqual(try store.fetchSuggestions(includeCompleted: false).count, 1)

        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "first-ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false),
                testMessage(id: "user-reply", sentAt: now.addingTimeInterval(-1 * 60 * 60), body: "Sent them.", isFromUser: true)
            ]
        )

        _ = try await engine.generateFromStoredMessages()
        let activeSuggestions = try store.fetchSuggestions(includeCompleted: false)

        XCTAssertEqual(activeSuggestions.count, 1)
        XCTAssertEqual(activeSuggestions.first?.state, .new)
        XCTAssertEqual(activeSuggestions.first?.type, .followUpNudge)
        XCTAssertEqual(activeSuggestions.first?.confidence, 0.16)
        XCTAssertEqual(activeSuggestions.first?.evidence.messageId, "message-test-source-user-reply")
    }

    func testOlderActiveThreadSuggestionsAreSupersededButTerminalStatesRemain() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let store = try MinderStore(databaseURL: databaseURL)
        let database = try SQLiteDatabase(url: databaseURL)
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "urgent", sentAt: now.addingTimeInterval(-45 * 60), body: "Can you send the notes by Friday?", isFromUser: false)
            ]
        )
        try insertLegacySuggestion(database, id: "legacy-active", state: .new, updatedAt: now.addingTimeInterval(-600))
        try insertLegacySuggestion(database, id: "legacy-dismissed", state: .dismissed, updatedAt: now.addingTimeInterval(-500))
        try insertLegacySuggestion(database, id: "legacy-completed", state: .completed, updatedAt: now.addingTimeInterval(-400))

        let draft = testDraft(
            type: .deadline,
            confidence: 0.90,
            messageId: "message-test-source-urgent",
            sourceTimestamp: now.addingTimeInterval(-45 * 60)
        )
        _ = try store.upsertSuggestions([draft])
        let suggestions = try store.fetchSuggestions()

        XCTAssertEqual(suggestions.first { $0.id == "legacy-active" }?.state, .superseded)
        XCTAssertEqual(suggestions.first { $0.id == "legacy-dismissed" }?.state, .dismissed)
        XCTAssertEqual(suggestions.first { $0.id == "legacy-completed" }?.state, .completed)
        XCTAssertEqual(try store.fetchSuggestions(includeCompleted: false).filter { $0.threadId == "thread-1" }.count, 1)
    }

    func testDeleteSuggestionsKeepsImportedMessagesAndSources() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        _ = try store.upsertSuggestions([
            testDraft(
                type: .unansweredQuestion,
                confidence: 0.84,
                messageId: "message-test-source-ask",
                sourceTimestamp: now.addingTimeInterval(-8 * 60 * 60)
            )
        ])

        try store.deleteSuggestions()

        XCTAssertTrue(try store.fetchSuggestions().isEmpty)
        XCTAssertEqual(try store.fetchMessages().count, 1)
        XCTAssertEqual(try store.fetchThreads().count, 1)
        XCTAssertEqual(try store.fetchSources().count, 1)
    }

    func testDeleteImportedConversationCacheKeepsProfileAndPermissions() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        let profile = UserProfile(displayName: "Kainoa", completedOnboardingAt: now)
        let manualItem = try store.createManualQueueItem(kind: .todo, title: "Keep this local item")
        try store.saveUserProfile(profile)
        try store.upsertPermissionHealth(PermissionHealth(kind: .contacts, state: .available, detail: "Contacts enabled."))
        try saveTestImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: now.addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        _ = try store.upsertSuggestions([
            testDraft(
                type: .unansweredQuestion,
                confidence: 0.84,
                messageId: "message-test-source-ask",
                sourceTimestamp: now.addingTimeInterval(-8 * 60 * 60)
            )
        ])

        try store.deleteImportedConversationCache()

        XCTAssertTrue(try store.fetchSuggestions().isEmpty)
        XCTAssertTrue(try store.fetchMessages().isEmpty)
        XCTAssertTrue(try store.fetchThreads().isEmpty)
        XCTAssertTrue(try store.fetchSources().isEmpty)
        XCTAssertEqual(try store.fetchUserProfile()?.displayName, "Kainoa")
        XCTAssertEqual(try store.fetchPermissionHealth(kind: .contacts)?.state, .available)
        XCTAssertEqual(try store.fetchManualQueueItems().first?.id, manualItem.id)
    }

    func testSourceDefaultsAreStrictlyMessagesAndSample() {
        let profile = UserProfile()

        XCTAssertEqual(SourceKind.allCases, [.sample, .appleMessages])
        XCTAssertEqual(profile.sourcePriority, [.appleMessages, .sample])
    }

    func testReleaseChannelControlsBundleIDAndDataDirectory() {
        XCTAssertEqual(NudgeReleaseChannel.dev.bundleIdentifier, "com.kainoanishida.nudge.dev")
        XCTAssertEqual(NudgeReleaseChannel.dev.appSupportDirectoryName, "NudgeDev")
        XCTAssertEqual(NudgeReleaseChannel.alpha.bundleIdentifier, "com.kainoanishida.nudge.alpha")
        XCTAssertEqual(NudgeReleaseChannel.alpha.appSupportDirectoryName, "NudgeAlpha")
        XCTAssertEqual(NudgeReleaseChannel.current(environment: ["NUDGE_RELEASE_CHANNEL": "alpha"]), .alpha)
    }

    func testStartupCleanupRemovesLegacyGmailData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let firstStore = try MinderStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try firstStore.saveUserProfile(UserProfile(displayName: "Kainoa", sourcePriority: [.appleMessages, .sample]))
        try saveTestImport(
            store: firstStore,
            messages: [
                testMessage(id: "messages-ask", sentAt: now, body: "Can you send the notes?", isFromUser: false)
            ]
        )

        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            "UPDATE user_profiles SET source_priority = ? WHERE id = ?",
            [.text(#"["appleMessages","gmail","sample"]"#), .text(UserProfile.defaultID)]
        )
        try database.execute(
            "INSERT INTO sources (id, name, kind, health, last_sync_at) VALUES (?, ?, ?, ?, ?)",
            [.text("gmail"), .text("Gmail"), .text("gmail"), .text("available"), .text(DateCoding.iso8601.string(from: now))]
        )
        try database.execute(
            "INSERT INTO threads (id, source_id, external_id, title, participant_labels, last_message_at, is_active) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text("thread-gmail"), .text("gmail"), .text("thread-gmail"), .text("Gmail Thread"), .text(#"["Maya"]"#), .text(DateCoding.iso8601.string(from: now)), .int(1)]
        )
        try database.execute(
            "INSERT INTO messages (id, source_id, thread_id, external_id, sender_label, sent_at, body, is_from_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [.text("message-gmail"), .text("gmail"), .text("thread-gmail"), .text("message-gmail"), .text("Maya"), .text(DateCoding.iso8601.string(from: now)), .text("Gmail body"), .int(0)]
        )
        try database.execute(
            """
            INSERT INTO suggestions (
                id, type, state, title, action_text, due_date, source_id, thread_id,
                message_id, source_app, thread_title, evidence_snippet, source_timestamp,
                confidence, created_at, updated_at, snoozed_until
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text("suggestion-gmail"),
                .text(SuggestionType.unansweredQuestion.rawValue),
                .text(SuggestionState.new.rawValue),
                .text("Reply"),
                .text("Reply"),
                .null,
                .text("gmail"),
                .text("thread-gmail"),
                .text("message-gmail"),
                .text("Gmail"),
                .text("Gmail Thread"),
                .text("Gmail body"),
                .text(DateCoding.iso8601.string(from: now)),
                .double(0.9),
                .text(DateCoding.iso8601.string(from: now)),
                .text(DateCoding.iso8601.string(from: now)),
                .null
            ]
        )
        try database.execute(
            "INSERT INTO permission_health (kind, state, detail, last_checked_at) VALUES (?, ?, ?, ?)",
            [.text("gmail"), .text("available"), .text("Legacy Gmail"), .text(DateCoding.iso8601.string(from: now))]
        )

        let cleanedStore = try MinderStore(databaseURL: databaseURL)

        XCTAssertEqual(try cleanedStore.fetchSources().map(\.id), ["test-source"])
        XCTAssertEqual(try cleanedStore.fetchMessages().map(\.sourceId), ["test-source"])
        XCTAssertTrue(try cleanedStore.fetchSuggestions(includeCompleted: true).isEmpty)
        XCTAssertEqual(try cleanedStore.fetchUserProfile()?.sourcePriority, [.appleMessages, .sample])
        XCTAssertTrue(try database.query("SELECT * FROM permission_health WHERE kind = ?", [.text("gmail")]).isEmpty)
    }

    func testPrototypeGenerationCanIgnoreSampleSources() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        let sources = [
            ConversationSource(id: "apple", name: "Apple Messages", kind: .appleMessages, lastSyncAt: now),
            ConversationSource(id: "sample", name: "Sample", kind: .sample, lastSyncAt: now)
        ]
        let threads = sources.map { source in
            ConversationThread(
                id: "thread-\(source.id)",
                sourceId: source.id,
                externalId: "thread-\(source.id)",
                title: source.name,
                participantLabels: [source.name],
                lastMessageAt: now
            )
        }
        let messages = sources.map { source in
            testMessage(
                id: "ask",
                sourceId: source.id,
                threadId: "thread-\(source.id)",
                sentAt: now.addingTimeInterval(-60),
                body: "Thinking about this.",
                isFromUser: false
            )
        }
        _ = try store.saveImport(source: sources[0], threads: [threads[0]], messages: [messages[0]])
        _ = try store.saveImport(source: sources[1], threads: [threads[1]], messages: [messages[1]])

        let policy = ConversationRecommendationPolicy(now: now)
        let generated = try await SuggestionEngine(
            store: store,
            rankingService: LocalConversationRankingService(policy: policy),
            recommendationPolicy: policy,
            enabledSourceKinds: [.appleMessages]
        ).generateFromStoredMessages()

        XCTAssertEqual(generated.count, 1)
        XCTAssertEqual(generated.first?.sourceId, "apple")
    }

    func testGenericRepliedAppleMessagesThreadCreatesLowPrioritySuggestion() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore()
        let source = ConversationSource(id: "apple", name: "Apple Messages", kind: .appleMessages, lastSyncAt: now)
        let thread = ConversationThread(
            id: "thread-apple",
            sourceId: source.id,
            externalId: "thread-apple",
            title: "Avery",
            participantLabels: ["Avery"],
            lastMessageAt: now
        )
        let messages = [
            testMessage(
                id: "inbound",
                sourceId: source.id,
                threadId: thread.id,
                sentAt: now.addingTimeInterval(-2 * 60 * 60),
                body: "Can you send the notes?",
                isFromUser: false
            ),
            testMessage(
                id: "user-reply",
                sourceId: source.id,
                threadId: thread.id,
                sentAt: now.addingTimeInterval(-60 * 60),
                body: "I am looking now.",
                isFromUser: true
            )
        ]
        _ = try store.saveImport(source: source, threads: [thread], messages: messages)

        let policy = ConversationRecommendationPolicy(now: now)
        let generated = try await SuggestionEngine(
            store: store,
            rankingService: LocalConversationRankingService(policy: policy),
            recommendationPolicy: policy,
            enabledSourceKinds: [.appleMessages]
        ).generateFromStoredMessages()

        let suggestion = try XCTUnwrap(generated.first)
        XCTAssertEqual(generated.count, 1)
        XCTAssertEqual(suggestion.type, .followUpNudge)
        XCTAssertEqual(suggestion.confidence, 0.16)
        XCTAssertEqual(suggestion.evidence.messageId, "message-apple-user-reply")
    }

    func testAppleMessagesSchemaValidatorHandlesValidAndMissingSchemas() throws {
        let validURL = try makeMessagesDatabase(includeOldMessage: false)
        let validation = try AppleMessagesSchemaValidator.validate(databaseURL: validURL)
        XCTAssertTrue(validation.isCompatible)

        let missingURL = try makeIncompatibleMessagesDatabase()
        let missing = try AppleMessagesSchemaValidator.validate(databaseURL: missingURL)
        XCTAssertFalse(missing.isCompatible)
        XCTAssertTrue(missing.missingItems.contains("message.handle_id"))
        XCTAssertTrue(missing.missingItems.contains("chat.display_name"))
    }

    func testAppleMessagesImporterImportsRecentMessagesOnlyAndDedupes() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabase(includeOldMessage: true)
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)
        let cutoff = Date(timeIntervalSinceNow: -30 * 86_400)

        let first = try await importer.importRecent(into: store, since: cutoff)
        XCTAssertEqual(first.insertedSources, 1)
        XCTAssertEqual(first.insertedThreads, 1)
        XCTAssertEqual(first.insertedMessages, 2)
        XCTAssertEqual(first.skippedMessages, 0)

        let second = try await importer.importRecent(into: store, since: cutoff)
        XCTAssertEqual(second.insertedSources, 0)
        XCTAssertEqual(second.insertedThreads, 0)
        XCTAssertEqual(second.insertedMessages, 0)
        XCTAssertEqual(second.skippedMessages, 2)

        let messages = try store.fetchMessages()
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse(messages.contains { $0.body.contains("old message") })
        XCTAssertEqual(try store.fetchSources().first?.kind, .appleMessages)
    }

    func testAppleMessagesImporterKeepsNewestMessagesWhenLimited() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithOrderedMessages([
            (id: "old", body: "Old limited message", sentAt: Date(timeIntervalSinceNow: -10 * 86_400)),
            (id: "middle", body: "Middle limited message", sentAt: Date(timeIntervalSinceNow: -2 * 86_400)),
            (id: "new", body: "Newest limited message", sentAt: Date(timeIntervalSinceNow: -1 * 86_400))
        ])
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL, maxMessages: 2)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertFalse(messages.contains { $0.body == "Old limited message" })
        XCTAssertEqual(messages.map(\.body), ["Middle limited message", "Newest limited message"])
    }

    func testAppleMessagesImporterKeepsOutgoingReplyMarkersWhenTextIsMissing() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithMissingOutgoingText()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertEqual(messages.map(\.body), ["You didn't get me bagels...", "[Sent reply without plain text]"])
        XCTAssertEqual(messages.last?.isFromUser, true)

        let engine = SuggestionEngine(store: store, rankingService: LocalConversationRankingService())
        _ = try await engine.generateFromStoredMessages()

        let suggestions = try store.fetchSuggestions(includeCompleted: false)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.type, .followUpNudge)
        XCTAssertEqual(suggestions.first?.evidence.snippet, "[Sent reply without plain text]")
    }

    func testAppleMessagesImporterDecodesOutgoingAttributedBodyWhenTextIsMissing() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithOutgoingAttributedBody()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertEqual(messages.map(\.body), ["You didn't get me bagels...", "I brought bagels this time."])
        XCTAssertEqual(messages.last?.isFromUser, true)
    }

    func testAppleMessagesImporterDecodesLegacyTypedStreamAttributedBodyWhenTextIsMissing() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithLegacyTypedStreamOutgoingAttributedBody()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertEqual(messages.map(\.body), ["You didn't get me bagels...", "Typed stream reply text."])
        XCTAssertEqual(messages.last?.isFromUser, true)
    }

    func testAppleMessagesImporterExtractsEmbeddedAttributedBodyStringWhenArchivesCannotDecode() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithEmbeddedTextOutgoingAttributedBody()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertEqual(messages.map(\.body), ["You didn't get me bagels...", "Embedded reply text should be readable."])
        XCTAssertEqual(messages.last?.isFromUser, true)
    }

    func testAppleMessagesImporterFallsBackToPayloadDataWhenAttributedBodyCannotDecode() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithPayloadDataOutgoingBody()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertEqual(messages.map(\.body), ["You didn't get me bagels...", "Payload reply text should be readable."])
        XCTAssertEqual(messages.last?.isFromUser, true)
    }

    func testAppleMessagesImporterFallsBackToMessageSummaryInfoWhenAttributedBodyCannotDecode() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithMessageSummaryInfoOutgoingBody()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertEqual(messages.map(\.body), ["You didn't get me bagels...", "Summary reply text should be readable."])
        XCTAssertEqual(messages.last?.isFromUser, true)
    }

    func testAppleMessagesImporterFallsBackWhenOutgoingAttributedBodyCannotDecode() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithUndecodableOutgoingAttributedBody()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 2)
        XCTAssertEqual(messages.map(\.body), ["You didn't get me bagels...", "[Sent reply without plain text]"])
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    func testAppleMessagesTextDiagnosticsCountsAttributedBodiesAndNonTextRows() throws {
        let cutoff = Date(timeIntervalSinceNow: -30 * 86_400)
        let databaseURL = try makeMessagesDatabaseForTextDiagnostics()
        let diagnostics = try AppleMessagesConversationImporter(databaseURL: databaseURL).textDiagnostics(since: cutoff)

        XCTAssertEqual(diagnostics.outgoingWithPlainText, 1)
        XCTAssertEqual(diagnostics.outgoingWithoutPlainText, 2)
        XCTAssertEqual(diagnostics.outgoingWithAttributedBody, 1)
        XCTAssertEqual(diagnostics.outgoingWithoutPlainTextWithAttributedBody, 1)
        XCTAssertEqual(diagnostics.outgoingDecodedFromAttributedBody, 1)
        XCTAssertEqual(diagnostics.outgoingDecodedFromPayloadData, 0)
        XCTAssertEqual(diagnostics.outgoingDecodedFromMessageSummaryInfo, 0)
        XCTAssertEqual(diagnostics.outgoingUnresolvedAfterDecode, 1)
        XCTAssertEqual(diagnostics.recoveredOutgoingWithoutPlainTextCount, 1)
        XCTAssertEqual(diagnostics.attachmentRows, 1)
        XCTAssertEqual(diagnostics.visibleNonTextRows, 1)
    }

    func testAppleMessagesTextDiagnosticsHandlesMissingAttributedBodyColumn() throws {
        let databaseURL = try makeMessagesDatabaseWithMissingOutgoingText()
        let diagnostics = try AppleMessagesConversationImporter(databaseURL: databaseURL).textDiagnostics(since: Date(timeIntervalSinceNow: -30 * 86_400))

        XCTAssertEqual(diagnostics.outgoingWithPlainText, 0)
        XCTAssertEqual(diagnostics.outgoingWithoutPlainText, 1)
        XCTAssertEqual(diagnostics.outgoingWithAttributedBody, 0)
        XCTAssertEqual(diagnostics.outgoingWithoutPlainTextWithAttributedBody, 0)
        XCTAssertEqual(diagnostics.outgoingDecodedFromAttributedBody, 0)
        XCTAssertEqual(diagnostics.outgoingDecodedFromPayloadData, 0)
        XCTAssertEqual(diagnostics.outgoingDecodedFromMessageSummaryInfo, 0)
        XCTAssertEqual(diagnostics.outgoingUnresolvedAfterDecode, 1)
    }

    func testAppleMessagesDecodeTraceReportsMomHunterAndKsmOutgoingRows() throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseForDecodeTrace()
        let cutoff = Date(timeIntervalSinceNow: -30 * 86_400)
        let report = try AppleMessagesConversationImporter(databaseURL: databaseURL).decodeTrace(
            threadTitleMatches: ["Mom", "Hunter", "ksm"],
            since: cutoff,
            limitPerThread: 12
        )

        XCTAssertEqual(report.unmatchedTitles, [])
        XCTAssertEqual(report.threadMatches.count, 3)
        XCTAssertEqual(report.outgoingRowCount, 6)
        XCTAssertEqual(report.placeholderRowCount, 1)
        XCTAssertTrue(try store.fetchMessages().isEmpty)

        let mom = try XCTUnwrap(report.threadMatches.first { $0.chatTitle == "Mom" })
        XCTAssertEqual(mom.chatKind, .direct)
        XCTAssertEqual(mom.chatGUID, "iMessage;-;+15555550100")
        XCTAssertEqual(mom.outgoingRows.count, 3)

        let momPlain = try XCTUnwrap(mom.outgoingRows.first { $0.messageGUID == "message-mom-plain" })
        XCTAssertTrue(momPlain.messageTextExists)
        XCTAssertEqual(momPlain.messageTextSnippet, "Oh no I do need to pay that, doing it rn")
        XCTAssertEqual(momPlain.finalBody, "Oh no I do need to pay that, doing it rn")
        XCTAssertNil(momPlain.failureReason)

        let momAttributed = try XCTUnwrap(mom.outgoingRows.first { $0.messageGUID == "message-mom-attributed" })
        XCTAssertFalse(momAttributed.messageTextExists)
        XCTAssertTrue(momAttributed.attributedBody.isPresent)
        XCTAssertGreaterThan(momAttributed.attributedBody.byteLength, 0)
        XCTAssertNotNil(momAttributed.attributedBody.hexPrefix)
        XCTAssertEqual(momAttributed.attributedBody.decodedSnippet, "Direct attributed reply text.")
        XCTAssertEqual(momAttributed.finalBody, "Direct attributed reply text.")
        XCTAssertNil(momAttributed.failureReason)

        let momUnresolved = try XCTUnwrap(mom.outgoingRows.first { $0.messageGUID == "message-mom-unresolved" })
        XCTAssertFalse(momUnresolved.messageTextExists)
        XCTAssertFalse(momUnresolved.attributedBody.isPresent)
        XCTAssertEqual(momUnresolved.finalBody, "[Sent reply without plain text]")
        XCTAssertEqual(momUnresolved.failureReason, "No message.text or supported blob columns had data.")

        let hunter = try XCTUnwrap(report.threadMatches.first { $0.chatTitle == "Hunter Matsukubo" })
        XCTAssertEqual(hunter.chatKind, .direct)
        XCTAssertEqual(hunter.outgoingRows.count, 2)

        let hunterPayload = try XCTUnwrap(hunter.outgoingRows.first { $0.messageGUID == "message-hunter-payload" })
        XCTAssertTrue(hunterPayload.payloadData.isPresent)
        XCTAssertEqual(hunterPayload.payloadData.decodedSnippet, "Direct payload reply text.")
        XCTAssertEqual(hunterPayload.finalBody, "Direct payload reply text.")

        let hunterSummary = try XCTUnwrap(hunter.outgoingRows.first { $0.messageGUID == "message-hunter-summary" })
        XCTAssertTrue(hunterSummary.messageSummaryInfo.isPresent)
        XCTAssertEqual(hunterSummary.messageSummaryInfo.decodedSnippet, "Direct summary reply text.")
        XCTAssertEqual(hunterSummary.finalBody, "Direct summary reply text.")

        let ksm = try XCTUnwrap(report.threadMatches.first { $0.chatTitle == "ksm" })
        XCTAssertEqual(ksm.chatKind, .group)
        XCTAssertEqual(ksm.chatGUID, "iMessage;+;chat-ksm")
        XCTAssertEqual(ksm.outgoingRows.first?.messageTextSnippet, "Group reply works.")
        XCTAssertEqual(ksm.outgoingRows.first?.finalBody, "Group reply works.")
    }

    func testAppleMessagesDecodeTraceMatchesDirectChatsByResolvedContactName() throws {
        let databaseURL = try makeMessagesDatabaseForDecodeTrace(
            includeDirectDisplayNames: false,
            includeMessageHandles: false,
            includeChatHandleJoin: false
        )
        let report = try AppleMessagesConversationImporter(
            databaseURL: databaseURL,
            contactResolver: FakeContactResolver(names: [
                "phone:5555550100": "Mom",
                "phone:5555550101": "Hunter Matsukubo"
            ])
        ).decodeTrace(
            threadTitleMatches: ["Mom", "Hunter", "ksm"],
            since: Date(timeIntervalSinceNow: -30 * 86_400),
            limitPerThread: 12
        )

        XCTAssertEqual(report.unmatchedTitles, [])
        XCTAssertEqual(report.threadMatches.count, 3)
        XCTAssertEqual(report.threadMatches.first { $0.requestedTitle == "Mom" }?.chatTitle, "Mom")
        XCTAssertEqual(report.threadMatches.first { $0.requestedTitle == "Hunter" }?.chatTitle, "Hunter Matsukubo")
        XCTAssertEqual(report.threadMatches.first { $0.requestedTitle == "ksm" }?.chatKind, .group)
    }

    func testAppleMessagesDecodeTraceMatchesStoredThreadAliases() throws {
        let databaseURL = try makeMessagesDatabaseForDecodeTrace(
            includeDirectDisplayNames: false,
            includeMessageHandles: false,
            includeChatHandleJoin: false
        )
        let report = try AppleMessagesConversationImporter(databaseURL: databaseURL).decodeTrace(
            threadTitleMatches: ["Mom"],
            aliasesByTitle: ["Mom": ["iMessage;-;+15555550100"]],
            since: Date(timeIntervalSinceNow: -30 * 86_400),
            limitPerThread: 12
        )

        XCTAssertEqual(report.unmatchedTitles, [])
        XCTAssertEqual(report.threadMatches.count, 1)
        XCTAssertEqual(report.threadMatches.first?.requestedTitle, "Mom")
        XCTAssertEqual(report.threadMatches.first?.chatGUID, "iMessage;-;+15555550100")
        XCTAssertEqual(report.threadMatches.first?.outgoingRows.count, 3)
    }
#endif

    func testAppleMessagesImporterKeepsInboundAttachmentWithoutText() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithInboundAttachment()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 1)
        XCTAssertEqual(messages.first?.body, "Image attachment")
        XCTAssertEqual(messages.first?.isFromUser, false)

        let generated = try await SuggestionEngine(store: store, rankingService: LocalConversationRankingService()).generateFromStoredMessages()
        XCTAssertTrue(generated.allSatisfy { $0.confidence < 0.85 })
    }

    func testAppleMessagesImporterKeepsVisibleInboundWithoutUsefulTextMetadata() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabaseWithVisibleNonTextInbound()
        let importer = AppleMessagesConversationImporter(databaseURL: databaseURL)

        let result = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))
        let messages = try store.fetchMessages()

        XCTAssertEqual(result.insertedMessages, 1)
        XCTAssertEqual(messages.first?.body, "Message without plain text")
        XCTAssertEqual(messages.first?.isFromUser, false)
    }

    func testContactHandleNormalizerHandlesPhoneEmailAndPunctuation() {
        XCTAssertEqual(ContactHandleNormalizer.lookupKeys(for: "Maya@example.COM"), ["email:maya@example.com"])
        XCTAssertTrue(ContactHandleNormalizer.lookupKeys(for: "+1 (555) 555-0100").contains("phone:5555550100"))
        XCTAssertTrue(ContactHandleNormalizer.lookupKeys(for: "555.555.0100").contains("phone:5555550100"))
        XCTAssertTrue(ContactHandleNormalizer.looksLikeRawHandle("+1 (555) 555-0100"))
        XCTAssertFalse(ContactHandleNormalizer.looksLikeRawHandle("Maya Chen"))
    }

    func testAppleMessagesImporterResolvesContactNamesAndFallsBackToHandle() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabase(includeOldMessage: false, chatTitle: nil, handle: "+1 (555) 555-0100")
        let importer = AppleMessagesConversationImporter(
            databaseURL: databaseURL,
            contactResolver: FakeContactResolver(names: ["phone:5555550100": "Avery Stone"])
        )

        _ = try await importer.importRecent(into: store, since: Date(timeIntervalSinceNow: -30 * 86_400))

        XCTAssertTrue(try store.fetchMessages().contains { $0.senderLabel == "Avery Stone" })
        XCTAssertEqual(try store.fetchThreads().first?.title, "Avery Stone")

        let fallbackStore = try makeStore()
        let fallbackImporter = AppleMessagesConversationImporter(databaseURL: databaseURL)
        _ = try await fallbackImporter.importRecent(into: fallbackStore, since: Date(timeIntervalSinceNow: -30 * 86_400))
        XCTAssertTrue(try fallbackStore.fetchMessages().contains { $0.senderLabel == "+1 (555) 555-0100" })
    }

    func testRepeatedMessagesImportUpdatesPhoneNumberLabelsWithoutDuplicating() async throws {
        let store = try makeStore()
        let databaseURL = try makeMessagesDatabase(includeOldMessage: false, chatTitle: nil, handle: "+15555550100")
        let cutoff = Date(timeIntervalSinceNow: -30 * 86_400)

        let first = try await AppleMessagesConversationImporter(databaseURL: databaseURL).importRecent(into: store, since: cutoff)
        XCTAssertEqual(first.insertedMessages, 2)
        XCTAssertEqual(try store.fetchMessages().first { !$0.isFromUser }?.senderLabel, "+15555550100")

        let second = try await AppleMessagesConversationImporter(
            databaseURL: databaseURL,
            contactResolver: FakeContactResolver(names: ["phone:5555550100": "Avery Stone"])
        ).importRecent(into: store, since: cutoff)

        XCTAssertEqual(second.insertedMessages, 0)
        XCTAssertEqual(second.skippedMessages, 2)
        XCTAssertEqual(try store.fetchMessages().count, 2)
        XCTAssertEqual(try store.fetchMessages().first { !$0.isFromUser }?.senderLabel, "Avery Stone")
        XCTAssertEqual(try store.fetchThreads().first?.title, "Avery Stone")
    }

    func testObsoleteSocialConnectorStringsAreAbsentFromUserFacingDocsAndUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "README.md",
            "docs/README.md",
            "docs/product-brief.md",
            "docs/prd.md",
            "docs/privacy-security-spec.md",
            "docs/technical-architecture.md",
            "docs/platform-feasibility-appendix.md",
            "docs/ux-spec.md",
            "Sources/MinderApp/OnboardingView.swift"
        ]
        let forbidden = ["Instagram", "Facebook", "Meta", "metaExport"]

        for path in relativePaths {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(path) still contains \(token)")
            }
        }
    }

    func testCloudAIDisabledByDefaultEvenWhenCredentialsExist() {
        let config = GeminiConfig(apiKey: "test-key")
        let defaultProfile = UserProfile(displayName: "Kainoa")
        XCTAssertEqual(SuggestionGeneratorFactory.mode(profile: nil, geminiConfig: config), .localFallback)
        XCTAssertEqual(SuggestionGeneratorFactory.mode(profile: defaultProfile, geminiConfig: config), .localFallback)

        var optedInProfile = defaultProfile
        optedInProfile.cloudAIEnabled = true
        XCTAssertEqual(SuggestionGeneratorFactory.mode(profile: optedInProfile, geminiConfig: config), .cloudAI)
        XCTAssertEqual(SuggestionGeneratorFactory.mode(profile: optedInProfile, geminiConfig: nil), .localFallback)
    }

    func testOnboardingPermissionCoordinatorStoresFakePermissionResults() async throws {
        let store = try makeStore()
        let fake = FakePermissionService(
            refreshHealth: [
                PermissionHealth(kind: .fullDiskAccess, state: .missing, detail: "Full Disk Access is missing."),
                PermissionHealth(kind: .appleMessages, state: .missing, detail: "Messages are paused."),
                PermissionHealth(kind: .contacts, state: .missing, detail: "Contacts are not requested."),
                PermissionHealth(kind: .notifications, state: .missing, detail: "Notifications are not requested."),
                PermissionHealth(kind: .calendar, state: .available, detail: "Calendar access is available."),
                PermissionHealth(kind: .reminders, state: .available, detail: "Reminders access is available.")
            ],
            requestedHealth: [
                .contacts: PermissionHealth(kind: .contacts, state: .available, detail: "Contacts are enabled."),
                .notifications: PermissionHealth(kind: .notifications, state: .available, detail: "Notifications are enabled.")
            ]
        )
        let coordinator = OnboardingPermissionCoordinator(store: store, service: fake)

        let refreshed = try await coordinator.refresh()
        XCTAssertEqual(refreshed.first { $0.kind == .fullDiskAccess }?.state, .missing)
        XCTAssertEqual(try store.fetchPermissionHealth(kind: .appleMessages)?.state, .missing)

        let requested = try await coordinator.request(.notifications)
        XCTAssertEqual(requested.state, .available)
        XCTAssertEqual(try store.fetchPermissionHealth(kind: .notifications)?.state, .available)

        let contacts = try await coordinator.request(.contacts)
        XCTAssertEqual(contacts.state, .available)
        XCTAssertEqual(try store.fetchPermissionHealth(kind: .contacts)?.state, .available)
    }

    func testRuntimeContextDisablesBundleOnlyPermissionAPIsForSwiftPMExecutable() {
        let swiftPMContext = AppRuntimeContext(bundleURL: URL(fileURLWithPath: "/tmp/Nudge/.build/arm64-apple-macosx/debug/"))

        XCTAssertFalse(swiftPMContext.isAppBundle)
        XCTAssertFalse(swiftPMContext.supportsUserNotifications)
        XCTAssertFalse(swiftPMContext.supportsDirectPermissionPrompts)
    }

    func testRuntimeContextEnablesBundleOnlyPermissionAPIsForAppBundle() {
        let appContext = AppRuntimeContext(bundleURL: URL(fileURLWithPath: "/Applications/Nudge.app"))

        XCTAssertTrue(appContext.isAppBundle)
        XCTAssertTrue(appContext.supportsUserNotifications)
        XCTAssertTrue(appContext.supportsDirectPermissionPrompts)
    }
}

private func makeStore(file: StaticString = #filePath, line: UInt = #line) throws -> MinderStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try MinderStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
}

private func makeSuggestionContext(messages: [Message], userProfile: UserProfile? = nil) -> SuggestionContext {
    let latest = messages.map(\.sentAt).max() ?? Date()
    return SuggestionContext(
        sources: [
            ConversationSource(id: "test-source", name: "Test Messages", kind: .sample)
        ],
        threads: [
            ConversationThread(
                id: "thread-1",
                sourceId: "test-source",
                externalId: "thread-1",
                title: "Avery",
                participantLabels: ["Avery"],
                lastMessageAt: latest
            )
        ],
        messages: messages,
        userProfile: userProfile
    )
}

private func testMessage(
    id: String,
    sourceId: String = "test-source",
    threadId: String = "thread-1",
    sentAt: Date,
    body: String,
    isFromUser: Bool
) -> Message {
    Message(
        id: "message-\(sourceId)-\(id)",
        sourceId: sourceId,
        threadId: threadId,
        externalId: id,
        senderLabel: isFromUser ? "Kainoa" : "Avery",
        sentAt: sentAt,
        body: body,
        isFromUser: isFromUser
    )
}

private func testDraft(
    type: SuggestionType,
    confidence: Double,
    messageId: String,
    sourceTimestamp: Date,
    sourceId: String = "test-source",
    threadId: String = "thread-1"
) -> SuggestionDraft {
    SuggestionDraft(
        type: type,
        title: "Review Avery",
        actionText: "Open the conversation and respond if needed.",
        confidence: confidence,
        sourceId: sourceId,
        threadId: threadId,
        messageId: messageId,
        sourceApp: "Test Messages",
        threadTitle: "Avery",
        evidenceSnippet: "Can you send the notes by Friday?",
        sourceTimestamp: sourceTimestamp
    )
}

private func localRankingPipeline(
    context: SuggestionContext,
    now: Date
) async throws -> (candidates: [ConversationRankingCandidate], decisions: [ConversationRankingDecision], drafts: [SuggestionDraft]) {
    let policy = ConversationRecommendationPolicy(now: now)
    let candidates = ConversationCandidateBuilder(policy: policy).candidates(from: context)
    let decisions = try await LocalConversationRankingService(policy: policy).rankCandidates(candidates, context: context)
    let drafts = policy.rankedDrafts(decisions, candidates: candidates, context: context)
    return (candidates, decisions, drafts)
}

private func testCandidate(context: SuggestionContext, latestMessage: Message) -> ConversationRankingCandidate {
    let thread = context.threadById[latestMessage.threadId]!
    let source = context.sourceById[latestMessage.sourceId]!
    return ConversationRankingCandidate(
        sourceId: source.id,
        sourceName: source.name,
        threadId: thread.id,
        threadTitle: thread.title,
        participantLabels: thread.participantLabels,
        userDisplayName: context.userProfile?.displayName ?? "",
        userAliases: context.userAliases,
        latestMessage: latestMessage,
        recentMessages: context.messages,
        lastUserReplyAt: context.messages.filter(\.isFromUser).map(\.sentAt).max(),
        reasonHints: ["directAsk"]
    )
}

private func saveTestImport(store: MinderStore, messages: [Message]) throws {
    let latest = messages.map(\.sentAt).max() ?? Date()
    let source = ConversationSource(id: "test-source", name: "Test Messages", kind: .sample, lastSyncAt: latest)
    let thread = ConversationThread(
        id: "thread-1",
        sourceId: "test-source",
        externalId: "thread-1",
        title: "Avery",
        participantLabels: ["Avery"],
        lastMessageAt: latest
    )
    _ = try store.saveImport(source: source, threads: [thread], messages: messages)
}

private func insertLegacySuggestion(
    _ database: SQLiteDatabase,
    id: String,
    state: SuggestionState,
    updatedAt: Date,
    type: SuggestionType = .staleReply,
    messageId: String = "legacy-message"
) throws {
    try database.execute(
        """
        INSERT INTO suggestions (
            id, type, state, title, action_text, due_date, source_id, thread_id,
            message_id, source_app, thread_title, evidence_snippet, source_timestamp,
            confidence, created_at, updated_at, snoozed_until
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            .text(id),
            .text(type.rawValue),
            .text(state.rawValue),
            .text("Legacy suggestion"),
            .text("Legacy action"),
            .null,
            .text("test-source"),
            .text("thread-1"),
            .text(messageId),
            .text("Test Messages"),
            .text("Avery"),
            .text("Legacy evidence"),
            .text(DateCoding.iso8601.string(from: updatedAt.addingTimeInterval(-60))),
            .double(0.80),
            .text(DateCoding.iso8601.string(from: updatedAt.addingTimeInterval(-120))),
            .text(DateCoding.iso8601.string(from: updatedAt)),
            .null
        ]
    )
}

private func legacySuggestionID(sourceId: String, threadId: String) -> String {
    "suggestion-current-\([sourceId, threadId].joined(separator: "|").stableHash)"
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data
}

private func geminiResponseData(text: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "candidates": [
            [
                "content": [
                    "parts": [
                        ["text": text]
                    ]
                ]
            ]
        ]
    ])
}

private func makeIncompatibleMessagesDatabase() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("incompatible-chat.db")
    let database = try SQLiteDatabase(url: url)
    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")
    return url
}

private func makeMessagesDatabase(
    includeOldMessage: Bool,
    chatTitle: String? = "Avery",
    handle: String = "+15555550100"
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")

    try database.execute(
        "INSERT INTO chat (guid, display_name) VALUES (?, ?)",
        [.text("iMessage;-;chat-one"), chatTitle.map(SQLiteValue.text) ?? .null]
    )
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text(handle)])

    let recentIncoming = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -2 * 86_400))
    let recentOutgoing = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -1 * 86_400))

    try database.execute(
        "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?)",
        [.text("message-recent-in"), .text("Can you send the form by Friday?"), .int(Int(recentIncoming)), .int(0), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(1)])
    try database.execute(
        "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?)",
        [.text("message-recent-out"), .text("I'll send it tomorrow."), .int(Int(recentOutgoing)), .int(1), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(2)])

    if includeOldMessage {
        let old = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -45 * 86_400))
        try database.execute(
            "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?)",
            [.text("message-old"), .text("old message outside the sync window"), .int(Int(old)), .int(0), .int(1)]
        )
        try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(3)])
    }

    return url
}

private func makeMessagesDatabaseWithOrderedMessages(_ orderedMessages: [(id: String, body: String, sentAt: Date)]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")

    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;-;limited-chat"), .text("Avery")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550100")])

    for (index, message) in orderedMessages.enumerated() {
        try database.execute(
            "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?)",
            [
                .text("message-\(message.id)"),
                .text(message.body),
                .int(Int(AppleMessagesDateCodec.messageDateValue(from: message.sentAt))),
                .int(0),
                .int(1)
            ]
        )
        try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(index + 1)])
    }

    return url
}

private func makeMessagesDatabaseWithMissingOutgoingText() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")

    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;-;bagels-chat"), .text("jessie")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550101")])

    let inbound = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -2 * 86_400))
    let outbound = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -2 * 86_400 + 300))

    try database.execute(
        "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?)",
        [.text("message-bagels-in"), .text("You didn't get me bagels..."), .int(Int(inbound)), .int(0), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(1)])

    try database.execute(
        "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?)",
        [.text("message-bagels-reply"), .null, .int(Int(outbound)), .int(1), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(2)])

    return url
}

private func makeMessagesDatabaseWithOutgoingAttributedBody() throws -> URL {
    try makeMessagesDatabaseWithAttributedOutgoingBody(.blob(try archivedAttributedBody("I brought bagels this time.")))
}

private func makeMessagesDatabaseWithLegacyTypedStreamOutgoingAttributedBody() throws -> URL {
    try makeMessagesDatabaseWithAttributedOutgoingBody(.blob(legacyArchivedAttributedBody("Typed stream reply text.")))
}

private func makeMessagesDatabaseWithEmbeddedTextOutgoingAttributedBody() throws -> URL {
    try makeMessagesDatabaseWithAttributedOutgoingBody(.blob(embeddedPlainTextAttributedBody("Embedded reply text should be readable.")))
}

private func makeMessagesDatabaseWithPayloadDataOutgoingBody() throws -> URL {
    try makeMessagesDatabaseWithSupplementalOutgoingBody(
        payloadData: embeddedPlainTextAttributedBody("Payload reply text should be readable."),
        messageSummaryInfo: nil
    )
}

private func makeMessagesDatabaseWithMessageSummaryInfoOutgoingBody() throws -> URL {
    try makeMessagesDatabaseWithSupplementalOutgoingBody(
        payloadData: nil,
        messageSummaryInfo: embeddedPlainTextAttributedBody("Summary reply text should be readable.")
    )
}

private func makeMessagesDatabaseWithUndecodableOutgoingAttributedBody() throws -> URL {
    try makeMessagesDatabaseWithAttributedOutgoingBody(.blob(Data([0x00, 0x01, 0x02, 0x03])))
}

private func makeMessagesDatabaseWithAttributedOutgoingBody(_ attributedBody: SQLiteValue) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, attributedBody BLOB, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")

    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;-;bagels-chat"), .text("jessie")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550101")])

    let inbound = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -2 * 86_400))
    let outbound = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -2 * 86_400 + 300))

    try database.execute(
        "INSERT INTO message (guid, text, attributedBody, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?, ?)",
        [.text("message-bagels-in"), .text("You didn't get me bagels..."), .null, .int(Int(inbound)), .int(0), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(1)])

    try database.execute(
        "INSERT INTO message (guid, text, attributedBody, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?, ?)",
        [.text("message-bagels-reply"), .null, attributedBody, .int(Int(outbound)), .int(1), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(2)])

    return url
}

private func makeMessagesDatabaseForTextDiagnostics() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, attributedBody BLOB, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER, cache_has_attachments INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")
    try database.execute("CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, mime_type TEXT)")
    try database.execute("CREATE TABLE message_attachment_join (message_id INTEGER NOT NULL, attachment_id INTEGER NOT NULL)")

    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;-;diagnostics-chat"), .text("Avery")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550100")])

    let base = Date(timeIntervalSinceNow: -60 * 60)
    let rows: [(guid: String, text: SQLiteValue, attributedBody: SQLiteValue, isFromMe: Int, hasAttachment: Int)] = [
        ("message-in", .text("Can you send it?"), .null, 0, 0),
        ("message-out-plain", .text("Sent."), .null, 1, 0),
        ("message-out-attributed", .null, .blob(try archivedAttributedBody("Sent with attributed body.")), 1, 0),
        ("message-out-empty", .null, .null, 1, 0),
        ("message-in-attachment", .null, .null, 0, 1)
    ]

    for (index, row) in rows.enumerated() {
        let sentAt = AppleMessagesDateCodec.messageDateValue(from: base.addingTimeInterval(Double(index * 60)))
        try database.execute(
            "INSERT INTO message (guid, text, attributedBody, date, is_from_me, handle_id, cache_has_attachments) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(row.guid), row.text, row.attributedBody, .int(Int(sentAt)), .int(row.isFromMe), .int(1), .int(row.hasAttachment)]
        )
        try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(index + 1)])
    }

    try database.execute("INSERT INTO attachment (mime_type) VALUES (?)", [.text("image/png")])
    try database.execute("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)", [.int(5), .int(1)])

    return url
}

private func makeMessagesDatabaseForDecodeTrace(
    includeDirectDisplayNames: Bool = true,
    includeMessageHandles: Bool = true,
    includeChatHandleJoin: Bool = true
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, attributedBody BLOB, payload_data BLOB, message_summary_info BLOB, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")
    if includeChatHandleJoin {
        try database.execute("CREATE TABLE chat_handle_join (chat_id INTEGER NOT NULL, handle_id INTEGER NOT NULL)")
    }

    try database.execute(
        "INSERT INTO chat (guid, display_name) VALUES (?, ?)",
        [.text("iMessage;-;+15555550100"), includeDirectDisplayNames ? .text("Mom") : .null]
    )
    try database.execute(
        "INSERT INTO chat (guid, display_name) VALUES (?, ?)",
        [.text("iMessage;-;+15555550101"), includeDirectDisplayNames ? .text("Hunter Matsukubo") : .null]
    )
    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;+;chat-ksm"), .text("ksm")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550100")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550101")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("ksm@example.com")])
    if includeChatHandleJoin {
        try database.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", [.int(1), .int(1)])
        try database.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", [.int(2), .int(2)])
        try database.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", [.int(3), .int(3)])
    }

    let base = Date(timeIntervalSinceNow: -60 * 60)
    let rows: [(chatID: Int, guid: String, text: SQLiteValue, attributedBody: SQLiteValue, payloadData: SQLiteValue, messageSummaryInfo: SQLiteValue, handleID: Int)] = [
        (1, "message-mom-plain", .text("Oh no I do need to pay that, doing it rn"), .null, .null, .null, 1),
        (1, "message-mom-attributed", .null, .blob(try archivedAttributedBody("Direct attributed reply text.")), .null, .null, 1),
        (1, "message-mom-unresolved", .null, .null, .null, .null, 1),
        (2, "message-hunter-payload", .null, .blob(Data([0x00, 0x01, 0x02, 0x03])), .blob(embeddedPlainTextAttributedBody("Direct payload reply text.")), .null, 2),
        (2, "message-hunter-summary", .null, .blob(Data([0x00, 0x01, 0x02, 0x03])), .null, .blob(embeddedPlainTextAttributedBody("Direct summary reply text.")), 2),
        (3, "message-ksm-plain", .text("Group reply works."), .null, .null, .null, 3)
    ]

    for (index, row) in rows.enumerated() {
        let sentAt = AppleMessagesDateCodec.messageDateValue(from: base.addingTimeInterval(Double(index * 60)))
        try database.execute(
            "INSERT INTO message (guid, text, attributedBody, payload_data, message_summary_info, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(row.guid),
                row.text,
                row.attributedBody,
                row.payloadData,
                row.messageSummaryInfo,
                .int(Int(sentAt)),
                .int(1),
                includeMessageHandles ? .int(row.handleID) : .null
            ]
        )
        try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(row.chatID), .int(index + 1)])
    }

    return url
}

private func makeMessagesDatabaseWithSupplementalOutgoingBody(payloadData: Data?, messageSummaryInfo: Data?) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, attributedBody BLOB, payload_data BLOB, message_summary_info BLOB, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")

    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;-;bagels-chat"), .text("jessie")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550101")])

    let inbound = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -2 * 86_400))
    let outbound = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -2 * 86_400 + 300))

    try database.execute(
        "INSERT INTO message (guid, text, attributedBody, payload_data, message_summary_info, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [.text("message-bagels-in"), .text("You didn't get me bagels..."), .null, .null, .null, .int(Int(inbound)), .int(0), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(1)])

    try database.execute(
        "INSERT INTO message (guid, text, attributedBody, payload_data, message_summary_info, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
            .text("message-bagels-reply"),
            .null,
            .blob(Data([0x00, 0x01, 0x02, 0x03])),
            payloadData.map(SQLiteValue.blob) ?? .null,
            messageSummaryInfo.map(SQLiteValue.blob) ?? .null,
            .int(Int(outbound)),
            .int(1),
            .int(1)
        ]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(2)])

    return url
}

private func archivedAttributedBody(_ text: String) throws -> Data {
    try NSKeyedArchiver.archivedData(
        withRootObject: NSAttributedString(string: text),
        requiringSecureCoding: false
    )
}

private func legacyArchivedAttributedBody(_ text: String) -> Data {
    NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
}

private func embeddedPlainTextAttributedBody(_ text: String) -> Data {
    var data = Data([0x00, 0x11, 0x03])
    for chunk in ["NSAttributedString", "NSString", text, "NSFont"] {
        data.append(contentsOf: chunk.utf8)
        data.append(0x00)
    }
    return data
}

private func makeMessagesDatabaseWithInboundAttachment() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER, cache_has_attachments INTEGER)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")
    try database.execute("CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, mime_type TEXT, filename TEXT, transfer_name TEXT, uti TEXT)")
    try database.execute("CREATE TABLE message_attachment_join (message_id INTEGER NOT NULL, attachment_id INTEGER NOT NULL)")

    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;-;photo-chat"), .text("Avery")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550100")])

    let sentAt = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -60 * 60))
    try database.execute(
        "INSERT INTO message (guid, text, date, is_from_me, handle_id, cache_has_attachments) VALUES (?, ?, ?, ?, ?, ?)",
        [.text("message-photo"), .null, .int(Int(sentAt)), .int(0), .int(1), .int(1)]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(1)])
    try database.execute(
        "INSERT INTO attachment (mime_type, filename, transfer_name, uti) VALUES (?, ?, ?, ?)",
        [.text("image/png"), .text("photo.png"), .text("photo.png"), .text("public.png")]
    )
    try database.execute("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)", [.int(1), .int(1)])

    return url
}

private func makeMessagesDatabaseWithVisibleNonTextInbound() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")
    let database = try SQLiteDatabase(url: url)

    try database.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, display_name TEXT)")
    try database.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)")
    try database.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, handle_id INTEGER, associated_message_type INTEGER, balloon_bundle_id TEXT)")
    try database.execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)")

    try database.execute("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [.text("iMessage;-;balloon-chat"), .text("Avery")])
    try database.execute("INSERT INTO handle (id) VALUES (?)", [.text("+15555550100")])

    let sentAt = AppleMessagesDateCodec.messageDateValue(from: Date(timeIntervalSinceNow: -60 * 60))
    try database.execute(
        "INSERT INTO message (guid, text, date, is_from_me, handle_id, associated_message_type, balloon_bundle_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
            .text("message-balloon"),
            .null,
            .int(Int(sentAt)),
            .int(0),
            .int(1),
            .int(0),
            .text("com.apple.messages.MSMessageExtensionBalloonPlugin")
        ]
    )
    try database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(1), .int(1)])

    return url
}

private func base64URL(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private struct FakePermissionService: PermissionServicing {
    var refreshHealth: [PermissionHealth]
    var requestedHealth: [PermissionKind: PermissionHealth]

    func refreshPermissionHealth() async -> [PermissionHealth] {
        refreshHealth
    }

    func requestNotifications() async -> PermissionHealth {
        requestedHealth[.notifications] ?? PermissionHealth(kind: .notifications, state: .missing, detail: "Missing")
    }

    func requestContactsAccess() async -> PermissionHealth {
        requestedHealth[.contacts] ?? PermissionHealth(kind: .contacts, state: .missing, detail: "Missing")
    }

    func requestCalendarAccess() async -> PermissionHealth {
        requestedHealth[.calendar] ?? PermissionHealth(kind: .calendar, state: .missing, detail: "Missing")
    }

    func requestRemindersAccess() async -> PermissionHealth {
        requestedHealth[.reminders] ?? PermissionHealth(kind: .reminders, state: .missing, detail: "Missing")
    }

    func openSystemSettings(for kind: PermissionKind) async -> Bool {
        true
    }
}

private struct FakeContactResolver: ContactResolving {
    var names: [String: String]

    func displayName(for handle: String) -> String? {
        for key in ContactHandleNormalizer.lookupKeys(for: handle) {
            if let name = names[key] {
                return name
            }
        }
        return nil
    }
}

private final class MockGeminiURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
