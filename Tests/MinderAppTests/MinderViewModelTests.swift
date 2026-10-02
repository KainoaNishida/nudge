import XCTest
@testable import Nudge
@testable import MinderCore

@MainActor
final class MinderViewModelTests: XCTestCase {
    func testMessagesLinkUsesStoredThreadAndDoesNotCompleteSuggestion() throws {
        let store = try makeStore()
        let source = ConversationSource(id: "apple", name: "Apple Messages", kind: .appleMessages)
        let thread = ConversationThread(
            id: "thread-1", sourceId: source.id, externalId: "iMessage;-;+15551234567",
            title: "Avery", participantLabels: ["Avery"], lastMessageAt: Date()
        )
        _ = try store.saveImport(source: source, threads: [thread], messages: [])
        let suggestion = try XCTUnwrap(store.upsertSuggestions([testDraft(messageId: "message-apple-ask")]).first)
        let model = makeModel(store: store)
        model.refresh()

        let url = try XCTUnwrap(model.messagesURL(for: suggestion))
        XCTAssertEqual(url, AppleMessagesLink.url(threadExternalId: thread.externalId))
        XCTAssertEqual(model.suggestionCards.first?.messagesURL, url)
        XCTAssertEqual(model.activeAlertCount, 1)
        XCTAssertTrue(model.recentCompletedQueueItems.isEmpty)

        try store.updateSuggestionState(id: suggestion.id, state: .completed)
        model.refresh()
        XCTAssertEqual(model.messagesURL(for: suggestion), url)
        XCTAssertEqual(model.recentCompletedQueueItems.count, 1)
    }

    func testSampleThreadDoesNotProduceAMessagesLink() throws {
        let store = try makeStore()
        try saveMessagesImport(store: store, messages: [])
        let suggestion = try XCTUnwrap(store.upsertSuggestions([testDraft(messageId: "message-apple-ask")]).first)
        let model = makeModel(store: store)
        model.refresh()

        XCTAssertNil(model.messagesURL(for: suggestion))
        XCTAssertNil(model.suggestionCards.first?.messagesURL)
    }

    func testOpenSettingsSwitchesToSettingsTab() throws {
        let model = makeModel(store: try makeStore())

        XCTAssertEqual(model.selectedTab, .queue)

        model.openSettings()

        XCTAssertEqual(model.selectedTab, .settings)
    }

    func testToggleSettingsSwitchesBetweenSettingsAndQueue() throws {
        let model = makeModel(store: try makeStore())

        XCTAssertEqual(model.selectedTab, .queue)

        model.toggleSettings()

        XCTAssertEqual(model.selectedTab, .settings)

        model.toggleSettings()

        XCTAssertEqual(model.selectedTab, .queue)
    }

    func testQueuePresentationRanksNewestManualNotesAheadOfSuggestions() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: Date().addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        _ = try store.upsertSuggestions([
            testDraft(messageId: "message-apple-ask")
        ])
        let manualItem = ManualQueueItem(
            id: "manual-note-front",
            kind: .note,
            title: "Buy coffee",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        try store.upsertManualQueueItem(manualItem)

        let model = makeModel(store: store)
        model.refresh()

        XCTAssertEqual(model.activeQueueCount, 2)
        XCTAssertEqual(model.queueItems.count, 1)
        guard case .manual(let queuedManualItem) = try XCTUnwrap(model.queueItems.first) else {
            return XCTFail("Expected newest manual note to appear first.")
        }
        XCTAssertEqual(queuedManualItem.id, manualItem.id)

        model.goToNextQueuePage()

        guard case .suggestion(let card) = try XCTUnwrap(model.queueItems.first) else {
            return XCTFail("Expected generated suggestion after newer manual note.")
        }
        XCTAssertEqual(card.recentMessages.map(\.externalId), ["ask"])
    }

    func testQueuePresentationPaginatesActiveItems() throws {
        let store = try makeStore()
        for index in 1...7 {
            _ = try store.createManualQueueItem(kind: .todo, title: "Task \(index)")
        }

        let model = makeModel(store: store)
        model.refresh()

        XCTAssertEqual(model.activeQueueCount, 7)
        XCTAssertEqual(model.queueItems.count, MinderViewModel.queuePageSize)
        XCTAssertEqual(model.queuePageIndex, 0)
        XCTAssertEqual(model.queuePageNumber, 1)
        XCTAssertEqual(model.queuePageCount, 7)
        XCTAssertEqual(model.queuePageRangeText, "1 of 7")
        XCTAssertFalse(model.canGoToPreviousQueuePage)
        XCTAssertTrue(model.canGoToNextQueuePage)

        model.goToNextQueuePage()

        XCTAssertEqual(model.queuePageIndex, 1)
        XCTAssertEqual(model.queueItems.count, MinderViewModel.queuePageSize)
        XCTAssertEqual(model.queuePageNumber, 2)
        XCTAssertEqual(model.queuePageRangeText, "2 of 7")
        XCTAssertTrue(model.canGoToPreviousQueuePage)
        XCTAssertTrue(model.canGoToNextQueuePage)

        model.goToLastQueuePage()

        XCTAssertEqual(model.queuePageIndex, 6)
        XCTAssertEqual(model.queueItems.count, 1)
        XCTAssertEqual(model.queuePageNumber, 7)
        XCTAssertEqual(model.queuePageRangeText, "7 of 7")
        XCTAssertTrue(model.canGoToPreviousQueuePage)
        XCTAssertFalse(model.canGoToNextQueuePage)
    }

    func testQueuePaginationClampsWhenCurrentPageBecomesEmpty() throws {
        let store = try makeStore()
        for index in 1...4 {
            _ = try store.createManualQueueItem(kind: .todo, title: "Task \(index)")
        }

        let model = makeModel(store: store)
        model.refresh()
        model.goToLastQueuePage()

        XCTAssertEqual(model.queuePageIndex, 3)
        XCTAssertEqual(model.queueItems.count, 1)
        guard case .manual(let lastPageItem) = try XCTUnwrap(model.queueItems.first) else {
            return XCTFail("Expected a manual item on the last page.")
        }

        model.complete(lastPageItem)
        waitForModelWorkToFinish(model)

        XCTAssertEqual(model.activeQueueCount, 3)
        XCTAssertEqual(model.queuePageIndex, 2)
        XCTAssertEqual(model.queuePageNumber, 3)
        XCTAssertEqual(model.queuePageCount, 3)
        XCTAssertEqual(model.queuePageRangeText, "3 of 3")
        XCTAssertEqual(model.queueItems.count, 1)
    }

    func testCompletedManualItemsMoveOutOfActiveQueueAndCanBeUndone() throws {
        let store = try makeStore()
        let manualItem = try store.createManualQueueItem(kind: .note, title: "Ask Avery")
        try store.updateManualQueueItemState(id: manualItem.id, state: .completed)

        let model = makeModel(store: store)
        model.refresh()

        XCTAssertTrue(model.queueItems.isEmpty)
        XCTAssertEqual(model.recentCompletedQueueItems.count, 1)
        XCTAssertEqual(model.recentCompletedQueueItems.first?.title, "Ask Avery")

        model.undoCompleted(try XCTUnwrap(model.recentCompletedQueueItems.first))
        waitForModelWorkToFinish(model)

        XCTAssertEqual(model.queueItems.count, 1)
        guard case .manual(let restored) = model.queueItems[0] else {
            return XCTFail("Expected restored manual item.")
        }
        XCTAssertEqual(restored.state, .active)
    }

    func testDoneHistoryShowsAllRecentCompletedSuggestionsWithoutCountCap() throws {
        let store = try makeStore()
        let saved = try store.upsertSuggestions((1...7).map { index in
            testDraft(threadId: "thread-\(index)", messageId: "message-apple-ask-\(index)")
        })
        for suggestion in saved {
            try store.updateSuggestionState(id: suggestion.id, state: .completed)
        }

        let model = makeModel(store: store)
        model.refresh()

        XCTAssertEqual(model.recentCompletedQueueItems.count, 7)
    }

    func testDoneHistoryHidesItemsCompletedMoreThanOneDayAgo() throws {
        let store = try makeStore()
        let now = Date()
        for index in 1...3 {
            try store.upsertManualQueueItem(ManualQueueItem(
                id: "recent-\(index)",
                kind: .note,
                title: "Recent \(index)",
                state: .completed,
                createdAt: now.addingTimeInterval(-3_600),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                completedAt: now.addingTimeInterval(TimeInterval(-index))
            ))
        }
        try store.upsertManualQueueItem(ManualQueueItem(
            id: "expired",
            kind: .note,
            title: "Expired",
            state: .completed,
            createdAt: now.addingTimeInterval(-MinderViewModel.doneVisibleDuration - 3_600),
            updatedAt: now.addingTimeInterval(-MinderViewModel.doneVisibleDuration - 60),
            completedAt: now.addingTimeInterval(-MinderViewModel.doneVisibleDuration - 60)
        ))

        let model = makeModel(store: store)
        model.refresh()

        XCTAssertEqual(model.recentCompletedQueueItems.map(\.title), ["Recent 1", "Recent 2", "Recent 3"])
    }

    func testGenerateSuggestionsRunsEvenWhenOtherWorkFlagIsActive() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let importer = FakeAppleMessagesImporter(
            result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 1)
        )
        let model = makeModel(store: store, messagesImporter: importer)
        model.refresh()
        model.isWorking = true

        XCTAssertTrue(model.canGenerateSuggestions)

        model.generateSuggestions()
        waitForModelSyncToFinish(model)

        XCTAssertTrue(model.isWorking)
        XCTAssertFalse(model.isGeneratingSuggestions)
        XCTAssertEqual(importer.importCallCount, 1)
        XCTAssertTrue(model.statusMessage.contains("Checked Messages"))
    }

    func testPeriodicSyncNotifiesForNewGeneratedAlerts() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: Date().addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let notifier = FakeAlertNotifier()
        let model = makeModel(
            store: store,
            messagesImporter: FakeAppleMessagesImporter(
                result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 1)
            ),
            alertNotifier: notifier
        )

        model.syncAndGenerateSuggestions(reason: .periodic)
        waitForModelSyncToFinish(model)

        XCTAssertEqual(notifier.notifiedAlertBatches.count, 1)
        XCTAssertEqual(notifier.notifiedAlertBatches.first?.count, 1)
        XCTAssertEqual(notifier.notifiedAlertBatches.first?.first?.evidence.messageId, "message-apple-ask")
    }

    func testPeriodicSyncDoesNotNotifyForUnchangedGeneratedAlerts() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: Date().addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        _ = try store.upsertSuggestions([
            testDraft(messageId: "message-apple-ask")
        ])
        let notifier = FakeAlertNotifier()
        let model = makeModel(
            store: store,
            messagesImporter: FakeAppleMessagesImporter(
                result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 1)
            ),
            alertNotifier: notifier
        )

        model.syncAndGenerateSuggestions(reason: .periodic)
        waitForModelSyncToFinish(model)

        XCTAssertTrue(notifier.notifiedAlertBatches.isEmpty)
    }

    func testManualSyncDoesNotNotifyForNewGeneratedAlerts() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: Date().addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let notifier = FakeAlertNotifier()
        let model = makeModel(
            store: store,
            messagesImporter: FakeAppleMessagesImporter(
                result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 1)
            ),
            alertNotifier: notifier
        )

        model.generateSuggestions()
        waitForModelSyncToFinish(model)

        XCTAssertTrue(notifier.notifiedAlertBatches.isEmpty)
    }

    func testQuietNotificationCadenceSuppressesPeriodicAlertNotification() throws {
        let store = try makeStore()
        try store.saveUserProfile(UserProfile(notificationCadence: .quiet, completedOnboardingAt: Date()))
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: Date().addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let notifier = FakeAlertNotifier()
        let model = makeModel(
            store: store,
            messagesImporter: FakeAppleMessagesImporter(
                result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 1)
            ),
            alertNotifier: notifier
        )

        model.syncAndGenerateSuggestions(reason: .periodic)
        waitForModelSyncToFinish(model)

        XCTAssertTrue(notifier.notifiedAlertBatches.isEmpty)
    }

    func testVisibleQueueSuppressesPeriodicAlertNotification() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", sentAt: Date().addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let notifier = FakeAlertNotifier()
        let model = makeModel(
            store: store,
            messagesImporter: FakeAppleMessagesImporter(
                result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 1)
            ),
            alertNotifier: notifier
        )
        model.isQueueInterfaceVisible = { true }

        model.syncAndGenerateSuggestions(reason: .periodic)
        waitForModelSyncToFinish(model)

        XCTAssertTrue(notifier.notifiedAlertBatches.isEmpty)
    }

    func testPeriodicSyncSendsOneDigestForMultipleNewAlerts() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            threadMessages: [
                ("thread-1", "Avery", testMessage(id: "ask-1", threadId: "thread-1", sentAt: Date().addingTimeInterval(-8 * 60 * 60), body: "Can you send the notes?", isFromUser: false)),
                ("thread-2", "Blake", testMessage(id: "ask-2", threadId: "thread-2", sentAt: Date().addingTimeInterval(-9 * 60 * 60), body: "Could you send the summary?", isFromUser: false))
            ]
        )
        let notifier = FakeAlertNotifier()
        let model = makeModel(
            store: store,
            messagesImporter: FakeAppleMessagesImporter(
                result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 2)
            ),
            alertNotifier: notifier
        )

        model.syncAndGenerateSuggestions(reason: .periodic)
        waitForModelSyncToFinish(model)

        XCTAssertEqual(notifier.notifiedAlertBatches.count, 1)
        XCTAssertEqual(notifier.notifiedAlertBatches.first?.count, 2)
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    func testRunAppleMessagesDecodeTraceStoresReportAndStatus() throws {
        let store = try makeStore()
        let trace = AppleMessagesDecodeTraceReport(
            checkedSince: Date(timeIntervalSince1970: 1_800_000_000 - 86_400),
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
            targetTitles: ["Mom", "Hunter", "ksm"],
            unmatchedTitles: [],
            threadMatches: [
                AppleMessagesDecodeTraceThread(
                    requestedTitle: "Mom",
                    chatTitle: "Mom",
                    chatGUID: "iMessage;-;+15555550100",
                    chatKind: .direct,
                    outgoingRows: [
                        AppleMessagesDecodeTraceRow(
                            messageGUID: "message-mom-out",
                            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
                            messageTextExists: false,
                            messageTextLength: 0,
                            messageTextSnippet: nil,
                            attributedBody: AppleMessagesBlobDecodeTrace(isPresent: false, byteLength: 0, hexPrefix: nil, decodedSnippet: nil),
                            payloadData: AppleMessagesBlobDecodeTrace(isPresent: false, byteLength: 0, hexPrefix: nil, decodedSnippet: nil),
                            messageSummaryInfo: AppleMessagesBlobDecodeTrace(isPresent: false, byteLength: 0, hexPrefix: nil, decodedSnippet: nil),
                            finalBody: "[Sent reply without plain text]",
                            failureReason: "No message.text or supported blob columns had data."
                        )
                    ]
                )
            ]
        )
        let importer = FakeAppleMessagesImporter(
            result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 0),
            decodeTraceReport: trace
        )
        let model = makeModel(store: store, messagesImporter: importer)

        model.runAppleMessagesDecodeTrace()
        waitForModelWorkToFinish(model)

        XCTAssertEqual(importer.decodeTraceCallCount, 1)
        XCTAssertEqual(model.appleMessagesDecodeTraceReport, trace)
        XCTAssertTrue(model.statusMessage.contains("1 chat matches"))
        XCTAssertTrue(model.statusMessage.contains("1 placeholders"))
    }

    func testRunAppleMessagesDecodeTracePassesStoredDirectChatAliases() throws {
        let store = try makeStore()
        let source = ConversationSource(id: "apple", name: "Apple Messages", kind: .appleMessages, lastSyncAt: Date())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.saveImport(
            source: source,
            threads: [
                ConversationThread(
                    id: "thread-mom",
                    sourceId: source.id,
                    externalId: "iMessage;-;+15555550100",
                    title: "Mom",
                    participantLabels: ["Mom"],
                    lastMessageAt: now
                ),
                ConversationThread(
                    id: "thread-hunter",
                    sourceId: source.id,
                    externalId: "iMessage;-;+15555550101",
                    title: "Hunter Matsukubo",
                    participantLabels: ["Hunter Matsukubo"],
                    lastMessageAt: now
                )
            ],
            messages: []
        )
        let importer = FakeAppleMessagesImporter(
            result: ImportResult(insertedSources: 0, insertedThreads: 0, insertedMessages: 0, skippedMessages: 0)
        )
        let model = makeModel(store: store, messagesImporter: importer)

        model.runAppleMessagesDecodeTrace()
        waitForModelWorkToFinish(model)

        XCTAssertEqual(importer.decodeTraceCallCount, 1)
        XCTAssertEqual(importer.decodeTraceAliasesByTitle["Mom"]?.contains("iMessage;-;+15555550100"), true)
        XCTAssertEqual(importer.decodeTraceAliasesByTitle["Hunter"]?.contains("iMessage;-;+15555550101"), true)
        XCTAssertEqual(importer.decodeTraceAliasesByTitle["Hunter"]?.contains("Hunter Matsukubo"), true)
    }
#endif

    func testSuggestionMessagesLoadScrollableRecentWindowByDefault() throws {
        let store = try makeStore()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000 - 1_000)
        try saveMessagesImport(
            store: store,
            messages: (1...18).map { index in
                testMessage(
                    id: "m\(index)",
                    sentAt: baseDate.addingTimeInterval(TimeInterval(index)),
                    body: "Message \(index)",
                    isFromUser: index.isMultiple(of: 2)
                )
            }
        )
        _ = try store.upsertSuggestions([
            testDraft(messageId: "message-apple-m18")
        ])

        let model = makeModel(store: store)
        model.refresh()

        let expectedMessageIDs = (4...18).map { "m\($0)" }
        XCTAssertEqual(model.suggestionCards.count, 1)
        XCTAssertEqual(try XCTUnwrap(model.suggestionCards.first).recentMessages.map(\.externalId), expectedMessageIDs)
        let queueItem = try XCTUnwrap(model.queueItems.first)
        guard case .suggestion(let card) = queueItem else {
            return XCTFail("Expected suggestion queue item.")
        }
        XCTAssertEqual(card.recentMessages.count, MinderViewModel.suggestionPreviewMessageLimit)
        XCTAssertEqual(card.recentMessages.map(\.externalId), expectedMessageIDs)
    }

    func testActiveAlertCountExcludesManualAndInactiveSuggestions() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let saved = try store.upsertSuggestions([
            testDraft(type: .deadline, threadId: "active-deadline", messageId: "message-apple-ask"),
            testDraft(type: .followUpNudge, threadId: "active-follow-up", messageId: "message-apple-ask"),
            testDraft(type: .reminder, threadId: "completed-reminder", messageId: "message-apple-ask"),
            testDraft(type: .unansweredQuestion, threadId: "dismissed-question", messageId: "message-apple-ask"),
            testDraft(type: .staleReply, threadId: "superseded-stale", messageId: "message-apple-ask")
        ])
        try store.updateSuggestionState(id: saved[2].id, state: .completed)
        try store.updateSuggestionState(id: saved[3].id, state: .dismissed)
        try store.updateSuggestionState(id: saved[4].id, state: .superseded)
        _ = try store.createManualQueueItem(kind: .todo, title: "Manual item")

        let model = makeModel(store: store)
        model.refresh()

        XCTAssertEqual(model.activeAlertCount, 2)
        XCTAssertEqual(model.activeQueueCount, 3)
    }

    func testAlertLegendItemsCountActiveSuggestionsByType() throws {
        let store = try makeStore()
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", body: "Can you send the notes?", isFromUser: false)
            ]
        )
        let saved = try store.upsertSuggestions([
            testDraft(type: .deadline, threadId: "deadline", messageId: "message-apple-ask"),
            testDraft(type: .followUpNudge, threadId: "follow-up", messageId: "message-apple-ask"),
            testDraft(type: .unansweredQuestion, threadId: "inactive-question", messageId: "message-apple-ask")
        ])
        try store.updateSuggestionState(id: saved[2].id, state: .completed)

        let model = makeModel(store: store)
        model.refresh()

        XCTAssertEqual(model.alertLegendItems.map(\.type), SuggestionType.allCases)
        let counts = Dictionary(uniqueKeysWithValues: model.alertLegendItems.map { ($0.type, $0.count) })
        XCTAssertEqual(counts[.deadline], 1)
        XCTAssertEqual(counts[.followUpNudge], 1)
        XCTAssertEqual(counts[.unansweredQuestion], 0)
        XCTAssertEqual(counts[.calendarEvent], 0)
    }

    func testSettingsPrivacyDeleteActionsClearImportedCacheButKeepManualItemsAndProfile() throws {
        let store = try makeStore()
        try store.saveUserProfile(UserProfile(displayName: "Kainoa", completedOnboardingAt: Date()))
        let manualItem = try store.createManualQueueItem(kind: .todo, title: "Keep this")
        try saveMessagesImport(
            store: store,
            messages: [
                testMessage(id: "ask", body: "Can you send the notes?", isFromUser: false)
            ]
        )
        _ = try store.upsertSuggestions([
            testDraft(messageId: "message-apple-ask")
        ])

        let model = makeOnboardingModel(store: store)
        model.clearImportedConversationCache()
        waitForOnboardingWorkToFinish(model)

        XCTAssertTrue(try store.fetchSources().isEmpty)
        XCTAssertTrue(try store.fetchMessages().isEmpty)
        XCTAssertTrue(try store.fetchSuggestions().isEmpty)
        XCTAssertEqual(try store.fetchManualQueueItems().first?.id, manualItem.id)
        XCTAssertEqual(try store.fetchUserProfile()?.displayName, "Kainoa")
    }

    func testCloudAIInputValidationAcceptsGeminiSettingsValues() throws {
        let store = try makeStore()
        let model = makeOnboardingModel(store: store)
        model.geminiAPIKeyInput = "stored-gemini-key"
        model.geminiModelInput = "gemini-2.5-flash"

        XCTAssertTrue(model.geminiInputValidation.isValid)
        XCTAssertEqual(model.geminiAPIKeyInput, "stored-gemini-key")
        XCTAssertEqual(model.geminiModelInput, "gemini-2.5-flash")
    }

    func testNotificationRequestFailureShowsActionableStatusMessage() throws {
        let store = try makeStore()
        let model = makeOnboardingModel(
            store: store,
            permissionService: FakePermissionService(notificationHealth: PermissionHealth(
                kind: .notifications,
                state: .degraded,
                detail: "macOS could not show the notification prompt. Open Notification Settings, enable Nudge, then click Check Again."
            ))
        )

        model.request(.notifications)
        waitForOnboardingWorkToFinish(model)

        XCTAssertTrue(model.statusMessage.contains("macOS could not show the notification prompt"))
        XCTAssertFalse(model.statusMessage.contains("Notifications: Degraded"))
    }

    func testOperationalStatusReadyWhenRequiredSetupIsAvailable() throws {
        let status = operationalStatus(
            permissionHealth: defaultPermissionHealth(),
            sources: [appleMessagesSource(lastSyncAt: Date())]
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Ready")
        XCTAssertEqual(status.shortTitle, "Working")
        XCTAssertEqual(status.targetSettingsStep, .about)
    }

    func testOperationalStatusLimitedWhenOptionalContactsAreMissing() throws {
        let status = operationalStatus(
            permissionHealth: defaultPermissionHealth(contacts: .missing),
            sources: [appleMessagesSource(lastSyncAt: Date())]
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.detail.contains("Messages permissions are working"))
    }

    func testOperationalStatusNeedsSetupWhenFullDiskAccessIsMissing() throws {
        let status = operationalStatus(
            permissionHealth: defaultPermissionHealth(fullDisk: .missing),
            sources: [appleMessagesSource(lastSyncAt: Date())]
        )

        XCTAssertEqual(status.state, .needsSetup)
        XCTAssertEqual(status.shortTitle, "Not working")
        XCTAssertEqual(status.targetSettingsStep, .messages)
    }

    func testOperationalStatusNeedsSetupWhenMessagesHaveNotImported() throws {
        let status = operationalStatus(
            permissionHealth: defaultPermissionHealth(),
            sources: []
        )

        XCTAssertEqual(status.state, .needsSetup)
        XCTAssertEqual(status.targetSettingsStep, .messages)
    }

    func testOperationalStatusReadyWithPetWhenSystemNotificationsAreDenied() throws {
        let status = operationalStatus(
            profile: UserProfile(notificationCadence: .hourlyDigest, completedOnboardingAt: Date()),
            permissionHealth: defaultPermissionHealth(notifications: .revoked),
            sources: [appleMessagesSource(lastSyncAt: Date())]
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Ready")
    }

    func testOperationalStatusReadyWithPetWhenSystemNotificationsWereNeverEnabled() throws {
        let status = operationalStatus(
            profile: UserProfile(notificationCadence: .hourlyDigest, completedOnboardingAt: Date()),
            permissionHealth: defaultPermissionHealth(notifications: .missing),
            sources: [appleMessagesSource(lastSyncAt: Date())]
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Ready")
    }

    func testOperationalStatusAllowsQuietCadenceWithoutNotificationPermission() throws {
        let status = operationalStatus(
            profile: UserProfile(notificationCadence: .quiet, completedOnboardingAt: Date()),
            permissionHealth: defaultPermissionHealth(notifications: .revoked),
            sources: [appleMessagesSource(lastSyncAt: Date())]
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.detail.contains("Messages permissions are working"))
    }

    func testOperationalStatusLimitedWhenCloudAIEnabledWithoutCredentials() throws {
        var profile = UserProfile(notificationCadence: .hourlyDigest, completedOnboardingAt: Date())
        profile.cloudAIEnabled = true

        let status = operationalStatus(
            profile: profile,
            permissionHealth: defaultPermissionHealth(),
            sources: [appleMessagesSource(lastSyncAt: Date())],
            hasCloudAIConfig: false
        )

        XCTAssertEqual(status.state, .limited)
        XCTAssertEqual(status.title, "Messages ready")
        XCTAssertEqual(status.targetSettingsStep, .cloudAI)
    }

    func testOperationalStatusLimitedWhenMessagesRefreshIsStale() throws {
        let status = operationalStatus(
            permissionHealth: defaultPermissionHealth(),
            sources: [appleMessagesSource(lastSyncAt: Date(timeIntervalSince1970: 1_800_000_000))],
            now: Date(timeIntervalSince1970: 1_800_000_000 + 3 * 60 * 60)
        )

        XCTAssertEqual(status.state, .limited)
        XCTAssertEqual(status.title, "Refresh recommended")
        XCTAssertEqual(status.targetSettingsStep, .messages)
    }

    func testNormalSettingsCopyHidesDeveloperBuildDetails() throws {
        let source = try sourceFileContents("Sources/MinderApp/OnboardingView.swift")

        XCTAssertFalse(source.contains("scripts/build-dev-app.sh"))
        XCTAssertFalse(source.contains(".build/NudgeDev"))
        XCTAssertFalse(source.contains("Current Running App"))
        XCTAssertFalse(source.contains("Relaunch Current Build"))
        XCTAssertFalse(source.contains("Bundle ID"))
        XCTAssertFalse(source.contains("Bundle path"))
        XCTAssertFalse(source.contains("Build stamp"))
    }

    func testAboutGuideExplainsUserJourney() throws {
        let source = try sourceFileContents("Sources/MinderApp/OnboardingView.swift")

        XCTAssertTrue(source.contains("How Nudge Works"))
        XCTAssertTrue(source.contains("Nudge reviews recent Apple Messages locally"))
        XCTAssertTrue(source.contains("Use Refresh"))
        XCTAssertTrue(source.contains("Mark alerts done"))
        XCTAssertTrue(source.contains("Notifications appear only for genuinely new alerts"))
        XCTAssertTrue(source.contains("Local mode works without Gemini credentials"))
        XCTAssertTrue(source.contains("requires email-code sign-in and separate data-sharing consent"))
    }

    func testQueueUsesDoneLanguageForCompletion() throws {
        let source = try sourceFileContents("Sources/MinderApp/Views.swift")

        XCTAssertTrue(source.contains("Label(\"Done\""))
        XCTAssertTrue(source.contains("Recently Done"))
        XCTAssertFalse(source.contains("Mark as Done"))
        XCTAssertFalse(source.contains("Recently Completed"))
    }

    func testSettingsIncludesStatusTroubleshootingTab() throws {
        let viewSource = try sourceFileContents("Sources/MinderApp/OnboardingView.swift")
        let modelSource = try sourceFileContents("Sources/MinderApp/OnboardingViewModel.swift")

        XCTAssertTrue(modelSource.contains("[.about, .status, .messages, .notifications, .privacy, .cloudAI, .appearance, .profile]"))
        XCTAssertTrue(viewSource.contains("StatusStep(model: model)"))
        XCTAssertTrue(viewSource.contains("Details"))
        XCTAssertTrue(viewSource.contains("Open \\(status.targetSettingsStep.title)"))
    }
}

@MainActor
private func makeModel(
    store: MinderStore,
    messagesImporter: any AppleMessagesImporting = AppleMessagesConversationImporter(),
    alertNotifier: any NudgeAlertNotifying = NudgeNoopAlertNotifier()
) -> MinderViewModel {
    MinderViewModel(
        store: store,
        permissionService: FakePermissionService(),
        messagesImporter: messagesImporter,
        alertNotifier: alertNotifier
    )
}

@MainActor
private func makeOnboardingModel(
    store: MinderStore,
    permissionService: any PermissionServicing = FakePermissionService(),
    geminiConfigStore: GeminiConfigStore = GeminiConfigStore()
) -> OnboardingViewModel {
    OnboardingViewModel(
        store: store,
        permissionService: permissionService,
        geminiConfigStore: geminiConfigStore,
        onComplete: {},
        onChange: {}
    )
}

private func makeStore() throws -> MinderStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinderAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try MinderStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
}

private func saveMessagesImport(store: MinderStore, messages: [Message]) throws {
    let source = ConversationSource(id: "apple", name: "Apple Messages", kind: .appleMessages, lastSyncAt: Date())
    let thread = ConversationThread(
        id: "thread-1",
        sourceId: source.id,
        externalId: "thread-1",
        title: "Avery",
        participantLabels: ["Avery"],
        lastMessageAt: messages.map(\.sentAt).max() ?? Date()
    )
    _ = try store.saveImport(source: source, threads: [thread], messages: messages)
}

private func saveMessagesImport(
    store: MinderStore,
    threadMessages: [(threadId: String, threadTitle: String, message: Message)]
) throws {
    let source = ConversationSource(id: "apple", name: "Apple Messages", kind: .appleMessages, lastSyncAt: Date())
    let threads = threadMessages.map { item in
        ConversationThread(
            id: item.threadId,
            sourceId: source.id,
            externalId: item.threadId,
            title: item.threadTitle,
            participantLabels: [item.threadTitle],
            lastMessageAt: item.message.sentAt
        )
    }
    _ = try store.saveImport(source: source, threads: threads, messages: threadMessages.map(\.message))
}

private func operationalStatus(
    profile: UserProfile = UserProfile(notificationCadence: .hourlyDigest, completedOnboardingAt: Date()),
    permissionHealth: [PermissionHealth],
    sources: [ConversationSource],
    lastRefreshFailed: Bool = false,
    hasCloudAIConfig: Bool = true,
    now: Date = Date()
) -> NudgeOperationalStatus {
    NudgeOperationalStatus.make(
        profile: profile,
        permissionHealth: permissionHealth,
        sources: sources,
        lastRefreshFailed: lastRefreshFailed,
        hasCloudAIConfig: hasCloudAIConfig,
        now: now
    )
}

private func defaultPermissionHealth(
    fullDisk: HealthState = .available,
    messages: HealthState = .available,
    notifications: HealthState = .available,
    contacts: HealthState = .available
) -> [PermissionHealth] {
    [
        PermissionHealth(kind: .fullDiskAccess, state: fullDisk, detail: fullDisk.rawValue),
        PermissionHealth(kind: .appleMessages, state: messages, detail: messages.rawValue),
        PermissionHealth(kind: .notifications, state: notifications, detail: notifications.rawValue),
        PermissionHealth(kind: .contacts, state: contacts, detail: contacts.rawValue)
    ]
}

private func appleMessagesSource(lastSyncAt: Date?) -> ConversationSource {
    ConversationSource(id: "apple", name: "Apple Messages", kind: .appleMessages, lastSyncAt: lastSyncAt)
}

private func sourceFileContents(_ path: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: packageRoot.appendingPathComponent(path))
}

private func testMessage(
    id: String,
    threadId: String = "thread-1",
    sentAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    body: String,
    isFromUser: Bool
) -> Message {
    Message(
        id: "message-apple-\(id)",
        sourceId: "apple",
        threadId: threadId,
        externalId: id,
        senderLabel: isFromUser ? "Me" : "Avery",
        sentAt: sentAt,
        body: body,
        isFromUser: isFromUser
    )
}

private func testDraft(
    type: SuggestionType = .unansweredQuestion,
    threadId: String = "thread-1",
    messageId: String
) -> SuggestionDraft {
    SuggestionDraft(
        type: type,
        title: "Reply to Avery",
        actionText: "Send the notes.",
        confidence: 0.84,
        sourceId: "apple",
        threadId: threadId,
        messageId: messageId,
        sourceApp: "Apple Messages",
        threadTitle: "Avery",
        evidenceSnippet: "Can you send the notes?",
        sourceTimestamp: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

@MainActor
private func waitForModelWorkToFinish(_ model: MinderViewModel) {
    let deadline = Date().addingTimeInterval(2)
    while model.isWorking && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func waitForModelSyncToFinish(_ model: MinderViewModel) {
    let deadline = Date().addingTimeInterval(2)
    while model.isGeneratingSuggestions && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func waitForOnboardingWorkToFinish(_ model: OnboardingViewModel) {
    let deadline = Date().addingTimeInterval(2)
    while model.isWorking && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

private struct FakePermissionService: PermissionServicing {
    var notificationHealth = PermissionHealth(kind: .notifications, state: .available, detail: "ok")

    func refreshPermissionHealth() async -> [PermissionHealth] { [] }
    func requestNotifications() async -> PermissionHealth {
        notificationHealth
    }
    func requestContactsAccess() async -> PermissionHealth {
        PermissionHealth(kind: .contacts, state: .available, detail: "ok")
    }
    func requestCalendarAccess() async -> PermissionHealth {
        PermissionHealth(kind: .calendar, state: .available, detail: "ok")
    }
    func requestRemindersAccess() async -> PermissionHealth {
        PermissionHealth(kind: .reminders, state: .available, detail: "ok")
    }
    func openSystemSettings(for kind: PermissionKind) async -> Bool { true }
}

@MainActor
private final class FakeAlertNotifier: NudgeAlertNotifying {
    private(set) var notifiedAlertBatches: [[Suggestion]] = []

    func notifyNewAlerts(_ alerts: [Suggestion]) async {
        notifiedAlertBatches.append(alerts)
    }
}

private final class FakeAppleMessagesImporter: AppleMessagesImporting {
    private let result: ImportResult
#if NUDGE_INTERNAL_DIAGNOSTICS
    private let decodeTraceReport: AppleMessagesDecodeTraceReport
#endif
    private(set) var importCallCount = 0
#if NUDGE_INTERNAL_DIAGNOSTICS
    private(set) var decodeTraceCallCount = 0
    private(set) var decodeTraceAliasesByTitle: [String: [String]] = [:]
#endif

#if NUDGE_INTERNAL_DIAGNOSTICS
    init(
        result: ImportResult,
        decodeTraceReport: AppleMessagesDecodeTraceReport = AppleMessagesDecodeTraceReport(
            checkedSince: Date(timeIntervalSince1970: 0),
            checkedAt: Date(timeIntervalSince1970: 0),
            targetTitles: [],
            unmatchedTitles: [],
            threadMatches: []
        )
    ) {
        self.result = result
        self.decodeTraceReport = decodeTraceReport
    }
#else
    init(result: ImportResult) {
        self.result = result
    }
#endif

    func importRecent(into store: MinderStore, since cutoff: Date) async throws -> ImportResult {
        importCallCount += 1
        return result
    }

#if NUDGE_INTERNAL_DIAGNOSTICS
    func textDiagnostics(since cutoff: Date) throws -> AppleMessagesTextDiagnostics {
        AppleMessagesTextDiagnostics(
            checkedSince: cutoff,
            outgoingWithPlainText: 0,
            outgoingWithoutPlainText: 0,
            outgoingWithAttributedBody: 0,
            outgoingWithoutPlainTextWithAttributedBody: 0,
            attachmentRows: 0,
            visibleNonTextRows: 0
        )
    }

    func decodeTrace(threadTitleMatches: [String], aliasesByTitle: [String: [String]], since cutoff: Date, limitPerThread: Int) throws -> AppleMessagesDecodeTraceReport {
        decodeTraceCallCount += 1
        decodeTraceAliasesByTitle = aliasesByTitle
        return decodeTraceReport
    }
#endif
}
