import SwiftUI
import MinderCore

private enum NudgeTheme {
    static let pageFill = Color(nsColor: .windowBackgroundColor)
    static let headerFill = dynamicColor(
        light: NSColor(calibratedWhite: 0.98, alpha: 1),
        dark: NSColor(calibratedWhite: 0.12, alpha: 1)
    )
    static let cardFill = dynamicColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 1),
        dark: NSColor(calibratedWhite: 0.15, alpha: 1)
    )
    static let elevatedFill = Color(nsColor: .controlBackgroundColor)
    static let controlFill = Color(nsColor: .textBackgroundColor)
    static let secondaryFill = Color(nsColor: .textBackgroundColor)
    static let text = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)

    static let blue = Color(red: 0.0, green: 0.38, blue: 0.82)
    static let green = Color(red: 0.13, green: 0.50, blue: 0.22)
    static let orange = Color(red: 0.70, green: 0.33, blue: 0.04)
    static let purple = Color(red: 0.43, green: 0.28, blue: 0.70)
    static let teal = Color(red: 0.05, green: 0.46, blue: 0.43)

    static let incomingBubble = dynamicColor(
        light: NSColor(calibratedRed: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1),
        dark: NSColor(calibratedRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)
    )
    static let iMessageBubble = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let smsBubble = Color(red: 0.16, green: 0.68, blue: 0.27)
    static let outgoingBubble = iMessageBubble
    static let completedFill = dynamicColor(
        light: NSColor(calibratedRed: 238 / 255, green: 248 / 255, blue: 241 / 255, alpha: 1),
        dark: NSColor(calibratedRed: 25 / 255, green: 54 / 255, blue: 38 / 255, alpha: 1)
    )

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private enum NudgeQueueLayout {
    static let appHeight: CGFloat = 620
    static let cardHeight: CGFloat = 450
    static let cardMaxWidth: CGFloat = 540
}

struct InboxView: View {
    @ObservedObject var model: MinderViewModel
    @ObservedObject var settingsModel: OnboardingViewModel

    private var palette: NudgePalette {
        if model.selectedTab == .settings {
            return settingsModel.profile.appColorScheme.palette
        }
        return (model.profile?.appColorScheme ?? settingsModel.profile.appColorScheme).palette
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .animation(nil, value: model.selectedTab)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 760, maxWidth: .infinity, minHeight: NudgeQueueLayout.appHeight, idealHeight: NudgeQueueLayout.appHeight, maxHeight: NudgeQueueLayout.appHeight)
        .environment(\.nudgePalette, palette)
        .tint(palette.primary)
        .background(NudgeTheme.pageFill)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 10) {
                NudgeAppMark()

                VStack(alignment: .leading, spacing: 1) {
                    Text("Nudge")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(NudgeTheme.text)
                    HStack(spacing: 7) {
                        Text(lastUpdatedText)
                            .font(.caption2)
                            .foregroundStyle(NudgeTheme.secondaryText)
                            .lineLimit(1)
                        if model.selectedTab == .queue {
                            QueueCountBadge(count: model.activeQueueCount)
                        } else if model.selectedTab == .done {
                            DoneCountBadge(count: model.recentCompletedQueueItems.count)
                        }
                    }
                    .frame(height: 14, alignment: .leading)
                }
                .offset(y: 1)
            }

            Spacer()

            HStack(spacing: 8) {
                if model.isShowingProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    model.generateSuggestions()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.primary)
                .disabled(!model.canGenerateSuggestions)
                .help("Refresh messages and alerts")

                NudgeMainTabSwitcher(
                    selectedTab: Binding(
                        get: { model.selectedTab },
                        set: { model.selectedTab = $0 }
                    ),
                    activeCount: model.activeQueueCount,
                    doneCount: model.recentCompletedQueueItems.count
                )

                Button {
                    model.quitNudge()
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Nudge")
            }
            .controlSize(.small)
        }
        .frame(height: 40)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background {
            ZStack(alignment: .bottom) {
                NudgeTheme.headerFill
                Rectangle()
                    .fill(palette.primary.opacity(0.16))
                    .frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .queue:
            queue
        case .done:
            DoneHistoryView(
                items: model.recentCompletedQueueItems,
                undo: { model.undoCompleted($0) }
            )
        case .settings:
            NudgeSettingsPanelView(model: settingsModel)
        }
    }

    private var queue: some View {
        HStack(alignment: .center, spacing: 12) {
            QueueArrowButton(
                systemImage: "chevron.left",
                help: "Previous queue item",
                isEnabled: model.canGoToPreviousQueuePage,
                action: { model.goToPreviousQueuePage() }
            )

            VStack(alignment: .center, spacing: 10) {
                if model.queueItems.isEmpty {
                    EmptyStateView(model: model)
                } else {
                    ForEach(model.queueItems) { item in
                        switch item {
                        case .suggestion(let card):
                            NudgeSuggestionCardView(
                                card: card,
                                complete: { model.complete(card.suggestion) }
                            )
                        case .manual(let manualItem):
                            ManualQueueItemCardView(item: manualItem) {
                                model.complete(manualItem)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            QueueArrowButton(
                systemImage: "chevron.right",
                help: "Next queue item",
                isEnabled: model.canGoToNextQueuePage,
                action: { model.goToNextQueuePage() }
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background {
            QueueStageBackground()
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            OperationalStatusButton(
                status: model.operationalStatus,
                isRefreshing: model.isGeneratingSuggestions
            ) {
                settingsModel.selectedStep = .status
                model.openSettings()
            }

            Spacer()

            if model.selectedTab == .queue && model.queuePageCount > 0 {
                QueueFooterPageIndicator(
                    pageNumber: model.queuePageNumber,
                    pageCount: model.queuePageCount
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(NudgeTheme.elevatedFill)
    }

    private var lastUpdatedText: String {
        if let source = model.appleMessagesSource, let sync = source.lastSyncAt {
            return "Last updated \(sync.relativeLabel)"
        }
        if model.appleMessagesCount > 0 {
            return "Messages loaded · refresh status unknown"
        }
        return "Not refreshed yet"
    }
}

private struct OperationalStatusButton: View {
    var status: NudgeOperationalStatus
    var isRefreshing: Bool
    var action: () -> Void

    private var tint: Color {
        status.state.tint
    }

    private var title: String {
        if isRefreshing {
            return "Refreshing"
        }
        return status.shortTitle
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 22, height: 5)
                Image(systemName: isRefreshing ? "arrow.clockwise" : status.systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NudgeTheme.tertiaryText)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .fixedSize(horizontal: true, vertical: false)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint.opacity(0.20), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("\(status.title): \(status.detail)")
    }
}

private struct NudgeAppMark: View {
    var body: some View {
        NudgeSymbol(size: 30)
    }
}

private struct QueueCountBadge: View {
    var count: Int

    var body: some View {
        Label(count == 1 ? "1 alert" : "\(count) alerts", systemImage: "tray.full")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NudgeTheme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(NudgeTheme.controlFill, in: Capsule())
    }
}

private struct DoneCountBadge: View {
    var count: Int

    var body: some View {
        Label(count == 1 ? "1 done" : "\(count) done", systemImage: "clock.arrow.circlepath")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NudgeTheme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(NudgeTheme.controlFill, in: Capsule())
    }
}

private struct NudgeMainTabSwitcher: View {
    @Environment(\.nudgePalette) private var palette

    @Binding var selectedTab: NudgeMainTab
    var activeCount: Int
    var doneCount: Int

    var body: some View {
        HStack(spacing: 3) {
            tabButton(.queue, count: activeCount)
            tabButton(.done, count: doneCount)
            tabButton(.settings, count: nil)
        }
        .padding(3)
        .background(NudgeTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(NudgeTheme.separator.opacity(0.55), lineWidth: 1)
        }
    }

    private func tabButton(_ tab: NudgeMainTab, count: Int?) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .font(.caption.weight(.semibold))
                Text(tab.title)
                    .font(.caption.weight(.semibold))
                if let count {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selectedTab == tab ? .white.opacity(0.85) : NudgeTheme.tertiaryText)
                }
            }
            .foregroundStyle(selectedTab == tab ? .white : NudgeTheme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selectedTab == tab ? palette.primary : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

private struct QueueStageBackground: View {
    @Environment(\.nudgePalette) private var palette

    var body: some View {
        ZStack {
            NudgeTheme.pageFill
            LinearGradient(
                colors: [
                    palette.primary.opacity(0.045),
                    NudgeTheme.pageFill,
                    palette.tertiary.opacity(0.035)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }
}

private struct QueueFooterPageIndicator: View {
    var pageNumber: Int
    var pageCount: Int

    var body: some View {
        Label("\(pageNumber)/\(pageCount)", systemImage: "rectangle.stack")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(NudgeTheme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NudgeTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(NudgeTheme.separator.opacity(0.6), lineWidth: 1)
            }
            .help("Queue page")
    }
}

private struct QueueArrowButton: View {
    @Environment(\.nudgePalette) private var palette

    var systemImage: String
    var help: String
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(isEnabled ? palette.primary : NudgeTheme.tertiaryText)
                .frame(width: 38, height: 74)
                .background(isEnabled ? palette.primary.opacity(0.10) : NudgeTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isEnabled ? palette.primary.opacity(0.22) : NudgeTheme.separator.opacity(0.45), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .shadow(color: .black.opacity(isEnabled ? 0.06 : 0), radius: 8, y: 3)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct NudgeSuggestionCardView: View {
    @Environment(\.nudgePalette) private var palette

    var card: NudgeSuggestionCard
    var complete: () -> Void

    var body: some View {
        let tint = card.suggestion.type.tint(in: palette)

        VStack(spacing: 10) {
            AlertCardShell(tint: tint) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        AlertGlyph(systemImage: card.suggestion.type.systemImage, tint: tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.suggestion.evidence.threadTitle)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(NudgeTheme.text)
                                .lineLimit(1)
                            Text(card.suggestion.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(NudgeTheme.secondaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(card.suggestion.evidence.sourceTimestamp.relativeLabel)
                            .font(.caption2)
                            .foregroundStyle(NudgeTheme.tertiaryText)
                            .lineLimit(1)
                    }

                    SuggestedActionStrip(text: card.suggestion.action.text, tint: tint)

                    ConversationPreview(messages: card.recentMessages, platform: card.messagePlatform)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }

            QueueCompletionButton(
                tint: tint,
                isDisabled: card.suggestion.state == .completed,
                action: complete
            )
        }
        .frame(maxWidth: NudgeQueueLayout.cardMaxWidth)
    }
}

private struct ManualQueueItemCardView: View {
    @Environment(\.nudgePalette) private var palette

    var item: ManualQueueItem
    var complete: () -> Void

    var body: some View {
        let tint = item.kind.tint(in: palette)

        VStack(spacing: 10) {
            AlertCardShell(tint: tint) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        AlertGlyph(systemImage: item.kind.systemImage, tint: tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(NudgeTheme.text)
                                .lineLimit(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(item.updatedAt.relativeLabel)
                            .font(.caption2)
                            .foregroundStyle(NudgeTheme.tertiaryText)
                            .lineLimit(1)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let body = item.body {
                                Text(body)
                                    .font(.callout)
                                    .foregroundStyle(NudgeTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("No extra details.")
                                    .font(.callout)
                                    .foregroundStyle(NudgeTheme.tertiaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }

            QueueCompletionButton(tint: tint, action: complete)
        }
        .frame(maxWidth: NudgeQueueLayout.cardMaxWidth)
    }
}

private struct AlertCardShell<Content: View>: View {
    var tint: Color
    private let content: Content

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .leading) {
            NudgeTheme.cardFill
            Rectangle()
                .fill(tint)
                .frame(width: 5)
            content
                .padding(12)
                .padding(.leading, 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, minHeight: NudgeQueueLayout.cardHeight, maxHeight: NudgeQueueLayout.cardHeight, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.09), radius: 18, y: 8)
    }
}

private struct AlertGlyph: View {
    var systemImage: String
    var tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.14))
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 34, height: 34)
    }
}

private struct SuggestedActionStrip: View {
    var text: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(NudgeTheme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct QueueCompletionButton: View {
    var tint: Color
    var isDisabled = false
    var action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .frame(minWidth: 116)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isDisabled)
        .shadow(color: tint.opacity(isDisabled ? 0 : 0.16), radius: 8, y: 3)
    }
}

private struct DoneHistoryView: View {
    @Environment(\.nudgePalette) private var palette
    @State private var openedItem: NudgeCompletedQueueItem?

    var items: [NudgeCompletedQueueItem]
    var undo: (NudgeCompletedQueueItem) -> Void

    var body: some View {
        ZStack {
            QueueStageBackground()
            if items.isEmpty {
                DoneEmptyState()
                    .frame(maxWidth: NudgeQueueLayout.cardMaxWidth)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Recently Done")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(NudgeTheme.text)
                        Spacer()
                        Text(items.count == 1 ? "1 item" : "\(items.count) items")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NudgeTheme.secondaryText)
                    }

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(items) { item in
                                DoneHistoryRow(
                                    item: item,
                                    open: { openedItem = item },
                                    undo: {
                                        if openedItem?.id == item.id {
                                            openedItem = nil
                                        }
                                        undo(item)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(16)
                .frame(maxWidth: NudgeQueueLayout.cardMaxWidth, minHeight: NudgeQueueLayout.cardHeight, maxHeight: NudgeQueueLayout.cardHeight, alignment: .topLeading)
                .background(NudgeTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.completion.opacity(0.20), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $openedItem) { item in
            DoneHistoryDetailView(item: item) {
                openedItem = nil
                undo(item)
            }
        }
    }
}

private struct DoneHistoryRow: View {
    @Environment(\.nudgePalette) private var palette

    var item: NudgeCompletedQueueItem
    var open: () -> Void
    var undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(palette.completion.opacity(0.13))
                        Image(systemName: item.systemImage)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(palette.completion)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(NudgeTheme.text)
                            .lineLimit(1)

                        Text(item.summary)
                            .font(.caption)
                            .foregroundStyle(NudgeTheme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Done \(item.updatedAt.relativeLabel)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(NudgeTheme.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NudgeTheme.tertiaryText)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open done item")

            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .controlSize(.small)
            .tint(palette.completion)
            .buttonStyle(.borderless)
            .help("Undo Done")
        }
        .padding(10)
        .background(NudgeTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.completion.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }
}

private struct DoneHistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nudgePalette) private var palette

    var item: NudgeCompletedQueueItem
    var undo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette.completion.opacity(0.14))
                    Image(systemName: item.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(palette.completion)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(NudgeTheme.text)
                        .lineLimit(2)
                    Text("Done \(item.updatedAt.detailLabel)")
                        .font(.caption)
                        .foregroundStyle(NudgeTheme.secondaryText)
                }

                Spacer(minLength: 8)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NudgeTheme.secondaryText)
                .help("Close")
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch item {
                    case .suggestion(let suggestion):
                        DetailPanel(title: "Suggested Action", systemImage: "checkmark.circle") {
                            Text(suggestion.action.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DetailPanel(title: "Evidence", systemImage: "quote.bubble") {
                            Text(suggestion.evidence.snippet)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DetailPanel(title: "Context", systemImage: "info.circle") {
                            VStack(spacing: 8) {
                                MetadataRow(title: "Alert", value: suggestion.title)
                                MetadataRow(title: "Source", value: suggestion.evidence.sourceApp)
                                MetadataRow(title: "Message", value: suggestion.evidence.sourceTimestamp.detailLabel)
                            }
                        }
                    case .manual(let manualItem):
                        DetailPanel(title: "Task", systemImage: manualItem.kind.systemImage) {
                            Text(manualItem.body?.nilIfBlank ?? manualItem.title)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DetailPanel(title: "Context", systemImage: "info.circle") {
                            VStack(spacing: 8) {
                                MetadataRow(title: "Created", value: manualItem.createdAt.relativeLabel)
                                MetadataRow(title: "Updated", value: manualItem.updatedAt.relativeLabel)
                            }
                        }
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button {
                    undo()
                } label: {
                    Label("Undo Done", systemImage: "arrow.uturn.backward")
                }
                .tint(palette.completion)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(18)
        }
        .frame(width: 440)
        .frame(minHeight: 420)
        .background(NudgeTheme.pageFill)
    }
}

private struct DoneEmptyState: View {
    @Environment(\.nudgePalette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.completion.opacity(0.14))
                    .frame(width: 68, height: 68)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(palette.completion)
            }
            Text("Nothing done yet")
                .font(.headline.weight(.semibold))
                .foregroundStyle(NudgeTheme.text)
            Text("Alerts you mark Done will show up here briefly, so you can undo them if needed.")
                .font(.caption)
                .foregroundStyle(NudgeTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
        .frame(maxWidth: NudgeQueueLayout.cardMaxWidth, minHeight: NudgeQueueLayout.cardHeight, maxHeight: NudgeQueueLayout.cardHeight)
        .background(NudgeTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.completion.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

private extension NudgeCompletedQueueItem {
    var systemImage: String {
        switch self {
        case .suggestion:
            return "checkmark.bubble"
        case .manual:
            return "checkmark.circle"
        }
    }

    var summary: String {
        switch self {
        case .suggestion(let suggestion):
            return suggestion.action.text
        case .manual(let item):
            return item.body?.nilIfBlank ?? "Manual task"
        }
    }
}

private struct ConversationPreview: View {
    var messages: [Message]
    var platform: NudgeMessagePlatform = .unknown

    var body: some View {
        Group {
            if messages.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { message in
                                MessageBubbleRow(message: message, platform: platform)
                                    .id(message.id)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NudgeTheme.secondaryFill.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(NudgeTheme.separator.opacity(0.65), lineWidth: 1)
                    }
                    .onAppear {
                        scrollToLatestMessage(with: proxy)
                    }
                    .onChange(of: messages.map(\.id)) { _, _ in
                        scrollToLatestMessage(with: proxy)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var emptyState: some View {
        Text("No recent messages available.")
            .font(.caption)
            .foregroundStyle(NudgeTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func scrollToLatestMessage(with proxy: ScrollViewProxy) {
        guard let latestMessageID = messages.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(latestMessageID, anchor: .bottom)
        }
    }
}

private struct MessageBubbleRow: View {
    var message: Message
    var platform: NudgeMessagePlatform

    var body: some View {
        let content = MessageBubbleContent(body: message.body)

        VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 3) {
            HStack {
                if message.isFromUser { Spacer(minLength: 64) }

                HStack(alignment: .top, spacing: 6) {
                    if let systemImage = content.systemImage {
                        Image(systemName: systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.top, 1)
                    }
                    Text(content.text)
                        .font(.caption)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .font(.caption)
                    .foregroundStyle(foregroundStyle(for: content))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(message.isFromUser ? platform.outgoingBubble : NudgeTheme.incomingBubble, in: RoundedRectangle(cornerRadius: 12))

                if !message.isFromUser { Spacer(minLength: 64) }
            }

            Text("\(message.isFromUser ? "You" : message.senderLabel) · \(message.sentAt.relativeLabel)")
                .font(.caption2)
                .foregroundStyle(NudgeTheme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: message.isFromUser ? .trailing : .leading)
    }

    private func foregroundStyle(for content: MessageBubbleContent) -> Color {
        if message.isFromUser {
            return .white
        }
        return content.isPlaceholder ? NudgeTheme.secondaryText : NudgeTheme.text
    }
}

private extension NudgeMessagePlatform {
    var outgoingBubble: Color {
        switch self {
        case .iMessage, .unknown:
            return NudgeTheme.iMessageBubble
        case .smsOrRCS:
            return NudgeTheme.smsBubble
        }
    }
}

private struct MessageBubbleContent {
    var text: String
    var systemImage: String?
    var isPlaceholder: Bool

    init(body: String) {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else {
            text = "Attachment"
            systemImage = "paperclip"
            isPlaceholder = true
            return
        }

        let lowercasedBody = normalizedBody.lowercased()
        if lowercasedBody == "image attachment" {
            text = "Image attachment"
            systemImage = "photo"
            isPlaceholder = true
        } else if lowercasedBody == "video attachment" {
            text = "Video attachment"
            systemImage = "video"
            isPlaceholder = true
        } else if lowercasedBody == "audio message" {
            text = "Audio message"
            systemImage = "waveform"
            isPlaceholder = true
        } else if lowercasedBody == "file attachment" {
            text = "File attachment"
            systemImage = "doc"
            isPlaceholder = true
        } else if lowercasedBody == "message without plain text" {
            text = "Message without plain text"
            systemImage = "bubble.left"
            isPlaceholder = true
        } else if lowercasedBody == "sent reply without plain text" || lowercasedBody == "[sent reply without plain text]" {
            text = "Sent reply without plain text"
            systemImage = "arrowshape.turn.up.left"
            isPlaceholder = true
        } else {
            text = normalizedBody
            systemImage = nil
            isPlaceholder = false
        }
    }
}

struct EmptyStateView: View {
    @Environment(\.nudgePalette) private var palette
    @ObservedObject var model: MinderViewModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.completion.opacity(0.14))
                    .frame(width: 68, height: 68)
                NudgeSymbol(size: 44)
            }
            Text("Nothing to complete")
                .font(.headline.weight(.semibold))
                .foregroundStyle(NudgeTheme.text)
            Text(model.messages.isEmpty ? "No messages checked yet." : "All caught up.")
                .font(.caption)
                .foregroundStyle(NudgeTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button {
                model.generateSuggestions()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.primary)
            .controlSize(.small)
            .disabled(!model.canGenerateSuggestions)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
        .frame(maxWidth: NudgeQueueLayout.cardMaxWidth, minHeight: NudgeQueueLayout.cardHeight, maxHeight: NudgeQueueLayout.cardHeight)
        .background(NudgeTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.completion.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

#if NUDGE_INTERNAL_DIAGNOSTICS
private struct GeminiDiagnosticsView: View {
    @ObservedObject var model: MinderViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.geminiDiagnostics.isEmpty && model.appleMessagesTextDiagnostics == nil && model.appleMessagesDecodeTraceReport == nil {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "stethoscope")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No diagnostics recorded")
                        .font(.headline)
                    Text("Run a Messages trace, run a Messages text check, or refresh with Gemini enabled to record diagnostics.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let report = model.appleMessagesDecodeTraceReport {
                            AppleMessagesDecodeTraceReportView(report: report)
                        }
                        if let diagnostics = model.appleMessagesTextDiagnostics {
                            AppleMessagesTextDiagnosticRow(diagnostics: diagnostics)
                        }
                        ForEach(model.geminiDiagnostics) { run in
                            GeminiDiagnosticRow(run: run)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 720, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshGeminiDiagnostics()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Diagnostics", systemImage: "stethoscope")
                    .font(.headline)
                Text("Gemini payloads stay redacted. The temporary Messages trace shows local snippets in memory only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.runAppleMessagesDecodeTrace()
            } label: {
                Label("Run Mom/Hunter Trace", systemImage: "text.magnifyingglass")
            }
            .disabled(model.isWorking)

            Button {
                model.runAppleMessagesTextDiagnostic()
            } label: {
                Label("Check Messages Text", systemImage: "message.badge.waveform")
            }
            .disabled(model.isWorking)

            Button {
                model.replayLatestGeminiRun()
            } label: {
                Label("Replay Latest", systemImage: "play.circle")
            }
            .disabled(model.geminiDiagnostics.isEmpty || model.isWorking)

            Button {
                model.copyLatestGeminiDiagnostics()
            } label: {
                Label("Copy Redacted Diagnostics", systemImage: "doc.on.doc")
            }
            .disabled(model.geminiDiagnostics.isEmpty)

            Button(role: .destructive) {
                model.clearGeminiDiagnostics()
            } label: {
                Label("Clear Diagnostics", systemImage: "trash")
            }
            .disabled(!hasAnyDiagnostics || model.isWorking)

            Button("Done") {
                model.isShowingGeminiDiagnostics = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(14)
    }

    private var hasAnyDiagnostics: Bool {
        !model.geminiDiagnostics.isEmpty
            || model.appleMessagesTextDiagnostics != nil
            || model.appleMessagesDecodeTraceReport != nil
    }
}

private struct AppleMessagesDecodeTraceReportView: View {
    var report: AppleMessagesDecodeTraceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(text: "Messages Decode Trace", systemImage: "text.magnifyingglass", tint: .orange)
                Spacer()
                Text(report.checkedAt.detailLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                MetricPill(title: "chat matches", value: "\(report.threadMatches.count)", systemImage: "bubble.left.and.bubble.right")
                MetricPill(title: "sent rows", value: "\(report.outgoingRowCount)", systemImage: "arrowshape.turn.up.left")
                MetricPill(title: "placeholders", value: "\(report.placeholderRowCount)", systemImage: "exclamationmark.bubble")
                MetricPill(title: "unmatched targets", value: "\(report.unmatchedTitles.count)", systemImage: "questionmark.circle")
            }

            if !report.unmatchedTitles.isEmpty {
                Text("No matching chat title or contact-resolved participant found for \(report.unmatchedTitles.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if report.threadMatches.isEmpty {
                Text("No matching Mom, Hunter, or ksm chats were found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(report.threadMatches) { thread in
                        AppleMessagesDecodeTraceThreadView(thread: thread, checkedSince: report.checkedSince)
                        if thread.id != report.threadMatches.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Text("Temporary local trace only. Snippets are not written to Nudge storage or files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct AppleMessagesDecodeTraceThreadView: View {
    var thread: AppleMessagesDecodeTraceThread
    var checkedSince: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.chatTitle)
                        .font(.subheadline.weight(.semibold))
                    Text("Matched \(thread.requestedTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: thread.chatKind.displayName, systemImage: thread.chatKind.systemImage, tint: thread.chatKind.tint)
                MetricPill(title: "sent rows", value: "\(thread.outgoingRows.count)", systemImage: "arrowshape.turn.up.left")
            }

            Text(thread.chatGUID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if thread.outgoingRows.isEmpty {
                Text("No outgoing rows found since \(checkedSince.detailLabel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(thread.outgoingRows) { row in
                        AppleMessagesDecodeTraceRowView(row: row)
                        if row.id != thread.outgoingRows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct AppleMessagesDecodeTraceRowView: View {
    var row: AppleMessagesDecodeTraceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusPill(
                    text: row.failureReason == nil ? "Readable" : "Placeholder",
                    systemImage: row.failureReason == nil ? "checkmark.bubble" : "exclamationmark.bubble",
                    tint: row.failureReason == nil ? .green : .red
                )
                Text(row.sentAt.detailLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(row.messageGUID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            DecodeTraceField(
                title: "message.text",
                value: messageTextValue
            )
            AppleMessagesBlobDecodeTraceLine(title: "attributedBody", trace: row.attributedBody)
            AppleMessagesBlobDecodeTraceLine(title: "payload_data", trace: row.payloadData)
            AppleMessagesBlobDecodeTraceLine(title: "message_summary_info", trace: row.messageSummaryInfo)
            DecodeTraceField(title: "final body", value: row.finalBody)

            if let failureReason = row.failureReason {
                DecodeTraceField(title: "failure", value: failureReason, tint: .red)
            }
        }
        .textSelection(.enabled)
    }

    private var messageTextValue: String {
        if let snippet = row.messageTextSnippet {
            return "present, \(row.messageTextLength) chars, snippet: \(snippet)"
        }
        if row.messageTextExists {
            return "present, \(row.messageTextLength) chars, no usable text after whitespace collapse"
        }
        return "missing"
    }
}

private struct AppleMessagesBlobDecodeTraceLine: View {
    var title: String
    var trace: AppleMessagesBlobDecodeTrace

    var body: some View {
        DecodeTraceField(title: title, value: value)
    }

    private var value: String {
        guard trace.isPresent else {
            return "missing"
        }

        var parts = ["present, \(trace.byteLength) bytes"]
        if let prefix = trace.hexPrefix {
            parts.append("prefix: \(prefix)")
        }
        if let decoded = trace.decodedSnippet {
            parts.append("decoded: \(decoded)")
        } else {
            parts.append("decoded: none")
        }
        return parts.joined(separator: " | ")
    }
}

private struct DecodeTraceField: View {
    var title: String
    var value: String
    var tint: Color?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(tint ?? .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private extension AppleMessagesChatKind {
    var systemImage: String {
        switch self {
        case .direct:
            return "person.crop.circle"
        case .group:
            return "person.3"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .direct:
            return .blue
        case .group:
            return .purple
        case .unknown:
            return .secondary
        }
    }
}

private struct AppleMessagesTextDiagnosticRow: View {
    var diagnostics: AppleMessagesTextDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(text: "Messages Text", systemImage: "message", tint: .accentColor)
                Spacer()
                Text("Since \(diagnostics.checkedSince.detailLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                MetricPill(title: "sent with plain text", value: "\(diagnostics.outgoingWithPlainText)", systemImage: "text.bubble")
                MetricPill(title: "sent without plain text", value: "\(diagnostics.outgoingWithoutPlainText)", systemImage: "exclamationmark.bubble")
                MetricPill(title: "sent with attributedBody", value: "\(diagnostics.outgoingWithAttributedBody)", systemImage: "doc.richtext")
                MetricPill(title: "decoded attributedBody", value: "\(diagnostics.outgoingDecodedFromAttributedBody)", systemImage: "doc.richtext")
                MetricPill(title: "decoded payload data", value: "\(diagnostics.outgoingDecodedFromPayloadData)", systemImage: "doc.badge.gearshape")
                MetricPill(title: "decoded summary info", value: "\(diagnostics.outgoingDecodedFromMessageSummaryInfo)", systemImage: "text.magnifyingglass")
                MetricPill(title: "still unresolved", value: "\(diagnostics.outgoingUnresolvedAfterDecode)", systemImage: "questionmark.bubble")
                MetricPill(title: "attachment rows", value: "\(diagnostics.attachmentRows)", systemImage: "paperclip")
                MetricPill(title: "visible non-text rows", value: "\(diagnostics.visibleNonTextRows)", systemImage: "ellipsis.bubble")
            }

            Text("Counts only. Nudge does not show or store raw diagnostic message bodies here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct GeminiDiagnosticRow: View {
    var run: GeminiDiagnosticRun
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusPill(text: run.outcome.displayName, systemImage: run.outcome.systemImage, tint: run.outcome.tint)
                StatusPill(text: run.errorCategory.displayName, systemImage: "tag", tint: run.outcome.tint)
                if let status = run.httpStatus {
                    StatusPill(text: "HTTP \(status)", systemImage: "network", tint: status >= 400 ? .red : .green)
                }
                if run.fallbackUsed {
                    StatusPill(text: "Fallback", systemImage: "arrow.uturn.left", tint: .orange)
                }
                Spacer()
                Text(run.createdAt.detailLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MetricPill(title: "Candidates", value: "\(run.candidateCount)", systemImage: "square.stack.3d.up")
                MetricPill(title: "Decisions", value: "\(run.decisionCount)", systemImage: "checklist")
                MetricPill(title: "Ranked", value: "\(run.rankedCount)", systemImage: "line.3.horizontal.decrease")
                MetricPill(title: "Saved", value: "\(run.savedCount)", systemImage: "tray.and.arrow.down")
                MetricPill(title: "ms", value: "\(run.durationMilliseconds)", systemImage: "timer")
            }

            VStack(alignment: .leading, spacing: 6) {
                MetadataRow(title: "Model", value: run.model)
                MetadataRow(title: "Run ID", value: run.id)
            }

            Text(run.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    diagnosticIDBlock(title: "Candidate thread IDs", values: run.candidateThreadIds)
                    diagnosticIDBlock(title: "Candidate message IDs", values: run.candidateMessageIds)
                }
                .padding(.top, 8)
            } label: {
                Text("Candidate IDs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func diagnosticIDBlock(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(values.isEmpty ? "none" : values.joined(separator: "\n"))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif

struct SuggestionRow: View {
    @Environment(\.nudgePalette) private var palette

    var suggestion: Suggestion
    var isSelected: Bool

    var body: some View {
        let tint = suggestion.type.tint(in: palette)

        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                Image(systemName: suggestion.type.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(suggestion.type.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(suggestion.state.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(stateColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                }

                Text(suggestion.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(suggestion.evidence.threadTitle)
                        .lineLimit(1)
                    Text("-")
                    Text(suggestion.evidence.sourceTimestamp.relativeLabel)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ConfidenceDot(confidence: suggestion.confidence)
                    Text(suggestion.confidenceLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? palette.primary.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var rowBackground: Color {
        isSelected ? palette.primary.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
    }

    private var stateColor: Color {
        switch suggestion.state {
        case .new, .viewed:
            return palette.primary
        case .confirmed, .completed:
            return .green
        case .snoozed:
            return .orange
        case .failed, .needsPermission:
            return .red
        case .dismissed, .superseded:
            return .secondary
        }
    }
}

struct SuggestionDetailView: View {
    @Environment(\.nudgePalette) private var palette

    @ObservedObject var model: MinderViewModel
    var suggestion: Suggestion?

    var body: some View {
        Group {
            if let suggestion {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailHeader(suggestion)
                        actionPanel(suggestion)
                        evidencePanel(suggestion)
                        metadataPanel(suggestion)
                        actionButtons(suggestion)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "sidebar.leading")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Select a suggestion")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detailHeader(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(text: suggestion.type.displayName, systemImage: suggestion.type.systemImage, tint: suggestion.type.tint(in: palette))
                StatusPill(text: suggestion.state.displayName, systemImage: suggestion.state.systemImage, tint: suggestion.state.tint)
                Spacer()
            }

            Text(suggestion.title)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Confidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(suggestion.confidence * 100))% - \(suggestion.confidenceLabel)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: suggestion.confidence)
                    .tint(suggestion.confidence >= 0.85 ? .green : palette.primary)
            }
        }
    }

    private func actionPanel(_ suggestion: Suggestion) -> some View {
        DetailPanel(title: "Suggested Action", systemImage: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text(suggestion.action.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let dueDate = suggestion.action.dueDate {
                    Label(dueDate.detailLabel, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func evidencePanel(_ suggestion: Suggestion) -> some View {
        DetailPanel(title: "Evidence", systemImage: "quote.bubble") {
            VStack(alignment: .leading, spacing: 10) {
                Text(suggestion.evidence.snippet)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label(suggestion.evidence.sourceApp, systemImage: "bubble.left")
                    Text("-")
                    Text(suggestion.evidence.sourceTimestamp.detailLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func metadataPanel(_ suggestion: Suggestion) -> some View {
        DetailPanel(title: "Context", systemImage: "info.circle") {
            VStack(spacing: 8) {
                MetadataRow(title: "Thread", value: suggestion.evidence.threadTitle)
                MetadataRow(title: "Source", value: suggestion.evidence.sourceApp)
                MetadataRow(title: "Created", value: suggestion.createdAt.relativeLabel)
                MetadataRow(title: "Updated", value: suggestion.updatedAt.relativeLabel)
                if let snoozedUntil = suggestion.snoozedUntil {
                    MetadataRow(title: "Snoozed Until", value: snoozedUntil.detailLabel)
                }
            }
        }
    }

    private func actionButtons(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if suggestion.state == .completed {
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } else {
                Button {
                    model.complete(suggestion)
                } label: {
                    Label("Done", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.top, 4)
    }
}

private struct DetailPanel<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct MetadataRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

private struct MetricPill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

private struct StatusPill: View {
    var text: String
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct SourceHealthStrip: View {
    var sources: [ConversationSource]
    var messages: [Message]
    var auditEvents: [AuditEvent]

    var body: some View {
        HStack(spacing: 8) {
            if sources.isEmpty {
                StatusPill(text: "No sources imported", systemImage: "tray", tint: .secondary)
            } else {
                ForEach(sources) { source in
                    StatusPill(text: "\(source.name): \(source.health.displayName)", systemImage: source.kind.systemImage, tint: source.health.tint)
                }
            }

            StatusPill(text: "\(messages.count) messages", systemImage: "text.bubble", tint: .secondary)

            if let latest = auditEvents.first {
                Text(latest.details)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }
}

private struct ConfidenceDot: View {
    var confidence: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Confidence \(Int(confidence * 100)) percent")
    }

    private var color: Color {
        if confidence >= 0.85 { return .green }
        if confidence >= 0.60 { return .orange }
        return .secondary
    }
}

private struct ConfidenceBadge: View {
    var confidence: Double

    var body: some View {
        HStack(spacing: 6) {
            ConfidenceDot(confidence: confidence)
            Text("\(Int(confidence * 100))%")
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(NudgeTheme.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(NudgeTheme.controlFill, in: Capsule())
        .help("Confidence")
    }
}

private extension SuggestionType {
    var systemImage: String {
        switch self {
        case .staleReply:
            return "timer"
        case .unansweredQuestion:
            return "questionmark.bubble"
        case .deadline:
            return "calendar.badge.clock"
        case .calendarEvent:
            return "calendar"
        case .reminder:
            return "checklist"
        case .promisedTask:
            return "hand.raised"
        case .importantContext:
            return "pin"
        case .followUpNudge:
            return "arrowshape.turn.up.right"
        }
    }

    func tint(in palette: NudgePalette) -> Color {
        switch self {
        case .deadline, .calendarEvent:
            return palette.primary
        case .unansweredQuestion, .staleReply:
            return palette.warning
        case .reminder, .promisedTask:
            return palette.tertiary
        case .importantContext:
            return palette.secondary
        case .followUpNudge:
            return palette.completion
        }
    }
}

private extension ManualQueueItemKind {
    var systemImage: String {
        switch self {
        case .todo:
            return "checklist"
        case .note:
            return "note.text"
        }
    }

    func tint(in palette: NudgePalette) -> Color {
        switch self {
        case .todo:
            return palette.completion
        case .note:
            return palette.secondary
        }
    }
}

private extension SuggestionState {
    var systemImage: String {
        switch self {
        case .new:
            return "sparkle"
        case .viewed:
            return "eye"
        case .confirmed:
            return "checkmark.seal"
        case .dismissed:
            return "xmark.circle"
        case .snoozed:
            return "clock"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .needsPermission:
            return "lock.open"
        case .superseded:
            return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .new, .viewed:
            return .accentColor
        case .confirmed, .completed:
            return .green
        case .snoozed:
            return .orange
        case .dismissed, .superseded:
            return .secondary
        case .failed, .needsPermission:
            return .red
        }
    }
}

private extension SourceKind {
    var systemImage: String {
        switch self {
        case .sample:
            return "shippingbox"
        case .appleMessages:
            return "message"
        }
    }
}

private extension HealthState {
    var displayName: String {
        switch self {
        case .available:
            return "Available"
        case .missing:
            return "Missing"
        case .degraded:
            return "Degraded"
        case .revoked:
            return "Revoked"
        case .unsupported:
            return "Unsupported"
        }
    }

    var tint: Color {
        switch self {
        case .available:
            return .green
        case .missing, .degraded:
            return .orange
        case .revoked:
            return .red
        case .unsupported:
            return .secondary
        }
    }
}

#if NUDGE_INTERNAL_DIAGNOSTICS
private extension GeminiDiagnosticOutcome {
    var displayName: String {
        switch self {
        case .success:
            return "Success"
        case .failure:
            return "Failure"
        case .skipped:
            return "Skipped"
        }
    }

    var systemImage: String {
        switch self {
        case .success:
            return "checkmark.circle"
        case .failure:
            return "exclamationmark.triangle"
        case .skipped:
            return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return .green
        case .failure:
            return .red
        case .skipped:
            return .secondary
        }
    }
}

private extension GeminiDiagnosticErrorCategory {
    var displayName: String {
        switch self {
        case .missingConfig:
            return "Missing Config"
        case .disabled:
            return "Disabled"
        case .noCandidates:
            return "No Candidates"
        case .network:
            return "Network"
        case .http:
            return "HTTP"
        case .missingOutput:
            return "Missing Output"
        case .invalidJSON:
            return "Invalid JSON"
        case .invalidEvidence:
            return "Invalid Evidence"
        case .success:
            return "Success"
        }
    }
}
#endif

private extension Date {
    var relativeLabel: String {
        DateFormatters.relative.localizedString(for: self, relativeTo: Date())
    }

    var detailLabel: String {
        DateFormatters.detail.string(from: self)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum DateFormatters {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static let detail: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
