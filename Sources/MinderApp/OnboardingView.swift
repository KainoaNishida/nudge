import AppKit
import SwiftUI
import MinderCore

private enum SettingsSurface {
    static let pageFill = Color(nsColor: .windowBackgroundColor)
    static let sidebarFill = Color(nsColor: .textBackgroundColor).opacity(0.42)
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let controlFill = Color(nsColor: .textBackgroundColor)
    static let text = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel

    private var palette: NudgePalette {
        model.profile.appColorScheme.palette
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    stepContent
                        .padding(24)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .environment(\.nudgePalette, palette)
        .tint(palette.primary)
        .background(SettingsSurface.pageFill)
        .onAppear {
            model.load()
            if !model.settingsSteps.contains(model.selectedStep) {
                model.selectedStep = .about
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSidebarHeader(
                title: model.profile.hasCompletedOnboarding ? "Nudge Settings" : "Nudge Setup",
                subtitle: "Permissions stay visible. Nothing connects silently."
            )

            VStack(spacing: 4) {
                ForEach(model.onboardingSteps) { step in
                    Button {
                        model.saveProfile()
                        model.selectedStep = step
                    } label: {
                        SettingsNavRow(step: step, isSelected: model.selectedStep == step)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                OperationalStatusSidebarView(status: model.operationalStatus)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(18)
        .frame(width: 230)
        .background {
            SettingsSidebarBackground()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.selectedStep {
        case .welcome:
            WelcomeStep()
        case .status:
            StatusStep(model: model)
        case .notifications:
            NotificationsStep(model: model)
        case .profile:
            ProfileStep(model: model)
        case .appearance:
            AppearanceStep(model: model)
        case .messages:
            MessagesStep(model: model)
        case .cloudAI:
            CloudAIStep(model: model)
        case .privacy:
            PrivacyStep(model: model)
        case .about:
            AboutStep()
        case .summary:
            SummaryStep(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                model.refreshPermissions()
            } label: {
                Label(recheckStatusTitle(for: model.selectedStep), systemImage: "arrow.clockwise")
            }

            Spacer()

            Button("Back") {
                model.back()
            }
            .disabled(!model.canMoveBack)

            if model.canMoveForward {
                Button {
                    model.next()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    model.completeOnboarding()
                } label: {
                    Label(model.profile.hasCompletedOnboarding ? "Done" : "Finish Setup", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .controlSize(.regular)
    }
}

struct NudgeSettingsPanelView: View {
    @ObservedObject var model: OnboardingViewModel

    private var palette: NudgePalette {
        model.profile.appColorScheme.palette
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    stepContent
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .environment(\.nudgePalette, palette)
        .tint(palette.primary)
        .background(SettingsSurface.pageFill)
        .onAppear {
            model.load()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.settingsSteps) { step in
                    Button {
                        model.saveProfile()
                        model.selectedStep = step
                    } label: {
                        SettingsNavRow(step: step, isSelected: model.selectedStep == step, isCompact: true)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(14)
        .frame(width: 192)
        .background {
            SettingsSidebarBackground()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.selectedStep {
        case .welcome:
            WelcomeStep()
        case .status:
            StatusStep(model: model)
        case .notifications:
            NotificationsStep(model: model)
        case .profile:
            ProfileStep(model: model)
        case .appearance:
            AppearanceStep(model: model)
        case .messages:
            MessagesStep(model: model)
        case .cloudAI:
            CloudAIStep(model: model)
        case .privacy:
            PrivacyStep(model: model)
        case .about:
            AboutStep()
        case .summary:
            SummaryStep(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                model.refreshPermissions()
            } label: {
                Label(recheckStatusTitle(for: model.selectedStep), systemImage: "arrow.clockwise")
            }

            Spacer()

            Button {
                model.completeOnboarding()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .controlSize(.small)
    }
}

private struct SettingsSidebarHeader: View {
    @Environment(\.nudgePalette) private var palette

    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsNudgeMark()
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(SettingsSurface.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(SettingsSurface.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(palette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.primary.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct SettingsNudgeMark: View {
    var body: some View {
        NudgeSymbol(size: 30)
    }
}

private struct SettingsNavRow: View {
    @Environment(\.nudgePalette) private var palette

    var step: OnboardingStep
    var isSelected: Bool
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? palette.primary.opacity(0.14) : SettingsSurface.controlFill.opacity(0.75))
                Image(systemName: step.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? palette.primary : SettingsSurface.secondaryText)
            }
            .frame(width: isCompact ? 22 : 26, height: isCompact ? 22 : 26)

            Text(step.title)
                .font((isCompact ? Font.caption : Font.callout).weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? SettingsSurface.text : SettingsSurface.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.primary)
                    .frame(width: 4, height: 18)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 6 : 7)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background(isSelected ? palette.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsSidebarBackground: View {
    @Environment(\.nudgePalette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            SettingsSurface.sidebarFill
            LinearGradient(
                colors: [palette.primary.opacity(0.10), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
            .allowsHitTesting(false)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    var tint: Color
    private let content: Content

    init(tint: Color = SettingsSurface.separator, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .leading) {
            SettingsSurface.cardFill
            Rectangle()
                .fill(tint.opacity(0.72))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .padding(.leading, 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Set up Nudge",
                subtitle: "Nudge reviews Apple Messages locally and gives you a short list of conversations you may want to complete."
            )

            VStack(alignment: .leading, spacing: 12) {
                PrincipleRow(systemImage: "lock.shield", title: "Local by default", detail: "Messages are imported read-only into a local cache for this prototype.")
                PrincipleRow(systemImage: "eye", title: "Clear setup", detail: "The app shows whether Messages, Full Disk Access, and optional Contacts are ready.")
                PrincipleRow(systemImage: "checkmark.circle", title: "One simple action", detail: "Each conversation gets at most one alert, and you can mark it completed when you are done.")
            }
        }
    }
}

private struct StatusStep: View {
    @ObservedObject var model: OnboardingViewModel

    private var status: NudgeOperationalStatus {
        model.operationalStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Status",
                subtitle: "See whether Nudge is working and the one thing to fix next."
            )

            OperationalStatusDetailCard(status: status) {
                model.selectedStep = status.targetSettingsStep
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Details")
                    .font(.headline)

                SourceSummaryRow(
                    title: "Apple Messages import",
                    systemImage: "message",
                    readiness: model.messagesReadiness,
                    health: model.health(for: .appleMessages),
                    source: model.source(for: .appleMessages),
                    importResult: model.lastImportResults[.appleMessages],
                    showsHealth: false
                )

                PermissionSummaryRow(health: model.health(for: .fullDiskAccess))
                PermissionSummaryRow(health: model.health(for: .notifications))
                PermissionSummaryRow(health: model.health(for: .contacts))
            }

            SetupPathBox(lines: statusHelpLines)
        }
    }

    private var statusHelpLines: [String] {
        switch status.state {
        case .ready:
            return [
                "Nudge is working. Messages access is available and recent Messages have imported.",
                "Notifications are ready, or your alert timing is set to Quiet."
            ]
        case .limited:
            return [
                "Nudge can still monitor Messages, but one supporting feature needs attention.",
                "Use the action above to jump to the setting most likely to explain the yellow status."
            ]
        case .needsSetup:
            return [
                "Nudge cannot fully monitor Messages yet.",
                "Use the action above, then click Check Again after changing permissions or importing Messages."
            ]
        }
    }
}

private struct OperationalStatusDetailCard: View {
    var status: NudgeOperationalStatus
    var action: () -> Void

    private var heading: String {
        switch status.state {
        case .ready:
            return "You are all set"
        case .limited, .needsSetup:
            return "Do this next"
        }
    }

    private var actionTitle: String {
        switch status.state {
        case .ready:
            return "Review How Nudge Works"
        case .limited, .needsSetup:
            return "Open \(status.targetSettingsStep.title)"
        }
    }

    var body: some View {
        SettingsCard(tint: status.state.tint) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SettingsSurface.secondaryText)
                .textCase(.uppercase)

            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(status.state.tint)
                    .frame(width: 28, height: 6)
                Label(status.shortTitle, systemImage: status.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(status.state.tint)
                Spacer()
            }

            Text(status.title)
                .font(.title3.weight(.semibold))
            Text(status.detail)
                .foregroundStyle(SettingsSurface.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: action) {
                Label(actionTitle, systemImage: status.targetSettingsStep.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

private struct ProfileStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Preferences",
                subtitle: "Small personal defaults Nudge uses when presenting your queue."
            )

            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Display name") {
                    TextField("Your name", text: $model.profile.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }

                LabeledContent("Timezone") {
                    TextField("Timezone", text: $model.profile.timeZoneIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
            }
        }
    }
}

private struct NotificationsStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Notifications",
                subtitle: "Choose whether Nudge should nudge you when a background refresh finds genuinely new alerts."
            )

            PermissionCard(
                health: model.health(for: .notifications),
                detail: notificationHelperText,
                primaryTitle: notificationPrimaryTitle,
                primarySystemImage: notificationPrimarySystemImage,
                primaryAction: notificationPrimaryAction,
                secondaryTitle: notificationSecondaryTitle,
                secondaryAction: notificationSecondaryAction
            )

            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Alert timing") {
                    Picker("When to notify", selection: $model.profile.notificationCadence) {
                        ForEach(NotificationCadence.allCases, id: \.rawValue) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }

                Stepper("Quiet hours start: \(timeLabel(model.profile.quietHoursStartMinutes))", value: $model.profile.quietHoursStartMinutes, in: 0...1439, step: 60)
                    .frame(maxWidth: 360, alignment: .leading)
                Stepper("Quiet hours end: \(timeLabel(model.profile.quietHoursEndMinutes))", value: $model.profile.quietHoursEndMinutes, in: 0...1439, step: 60)
                    .frame(maxWidth: 360, alignment: .leading)

                SetupPathBox(lines: [
                    "Quiet means Nudge still refreshes Messages, but it will not send system notifications.",
                    "If macOS notifications are off, Nudge can still build the queue. You just will not receive background digests."
                ])
            }
        }
        .onChange(of: model.profile.notificationCadence) { _, _ in
            model.saveProfile()
        }
    }

    private var notificationPrimaryTitle: String {
        switch model.health(for: .notifications).state {
        case .available:
            return "Check Notifications"
        case .revoked:
            return "Open Notification Settings"
        case .degraded, .unsupported:
            return "Open Notification Settings"
        case .missing:
            return "Enable Notifications"
        }
    }

    private var notificationPrimarySystemImage: String {
        switch model.health(for: .notifications).state {
        case .available:
            return "arrow.clockwise"
        case .revoked, .degraded, .unsupported:
            return "bell.badge"
        case .missing:
            return "bell"
        }
    }

    private var notificationPrimaryAction: () -> Void {
        switch model.health(for: .notifications).state {
        case .available:
            return { model.refreshPermissions() }
        case .revoked, .degraded, .unsupported:
            return { model.openSettings(for: .notifications) }
        case .missing:
            return { model.request(.notifications) }
        }
    }

    private var notificationSecondaryTitle: String? {
        switch model.health(for: .notifications).state {
        case .available, .missing:
            return "Open Notification Settings"
        case .revoked, .degraded, .unsupported:
            return "Check Again"
        }
    }

    private var notificationSecondaryAction: (() -> Void)? {
        switch model.health(for: .notifications).state {
        case .available, .missing:
            return { model.openSettings(for: .notifications) }
        case .revoked, .degraded, .unsupported:
            return { model.refreshPermissions() }
        }
    }

    private var notificationHelperText: String {
        switch model.health(for: .notifications).state {
        case .available:
            return "Nudge can send a digest when new alerts appear."
        case .missing:
            return "Click Enable Notifications to ask macOS for permission. Quiet mode keeps notifications off without limiting message monitoring."
        case .revoked:
            return "Notifications are off in macOS. Enable Nudge in Notification Settings, then click Check Again."
        case .degraded:
            return "The notification prompt did not complete. Open Notification Settings, enable Nudge if it appears, then click Check Again."
        case .unsupported:
            return "Notifications are unavailable in this launch mode. Use the packaged Nudge app to enable them."
        }
    }
}

private struct AppearanceStep: View {
    @ObservedObject var model: OnboardingViewModel

    private var palette: NudgePalette {
        model.profile.appColorScheme.palette
    }

    private var swatchColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 34, maximum: 40), spacing: 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Theme",
                subtitle: "Choose one accent color for Nudge."
            )

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Accent color")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(SettingsSurface.text)
                        Spacer()
                        Text(model.profile.appColorScheme.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SettingsSurface.secondaryText)
                    }

                    LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 10) {
                        ForEach(AppColorScheme.allCases, id: \.rawValue) { scheme in
                            AccentColorSwatchButton(
                                scheme: scheme,
                                isSelected: model.profile.appColorScheme == scheme,
                                select: { model.profile.appColorScheme = scheme }
                            )
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: 360, alignment: .leading)
                .background(SettingsSurface.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.primary.opacity(0.16), lineWidth: 1)
                }
            }
        }
        .onChange(of: model.profile.appColorScheme) { _, _ in
            model.saveProfile()
        }
    }
}

private struct AccentColorSwatchButton: View {
    var scheme: AppColorScheme
    var isSelected: Bool
    var select: () -> Void

    private var color: Color {
        scheme.palette.primary
    }

    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
                }
            }
            .frame(width: 34, height: 34)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? SettingsSurface.text : SettingsSurface.separator.opacity(0.65), lineWidth: isSelected ? 2 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(isSelected ? 0.50 : 0.24), lineWidth: 1)
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .help(scheme.displayName)
        .accessibilityLabel("\(scheme.displayName) accent color")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct MessagesStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Apple Messages",
                subtitle: "Connect Messages once, then Nudge can keep your alert queue fresh."
            )

            PermissionCard(
                health: model.health(for: .fullDiskAccess),
                detail: "Nudge needs Full Disk Access to read your local Messages database.",
                primaryTitle: "Open System Settings",
                primarySystemImage: "lock.open",
                primaryAction: { model.openSettings(for: .fullDiskAccess) },
                secondaryTitle: nil,
                secondaryAction: nil,
                helperText: "In Privacy & Security > Full Disk Access, add or enable Nudge. If macOS asks you to reopen the app, do that and come back to this screen."
            )

            SourceSetupCard(
                title: "Import Recent Messages",
                systemImage: "square.and.arrow.down",
                readiness: model.messagesReadiness,
                status: model.health(for: .appleMessages),
                detail: "Import the last 30 days so Nudge can build your first alert queue.",
                primaryTitle: "Import Messages",
                primarySystemImage: "message.fill",
                primaryDisabled: !model.canImportMessages,
                helperText: model.messagesNextAction,
                action: { model.importMessagesRecent() }
            )

            SourceSetupCard(
                title: "Contact Names Optional",
                systemImage: "person.crop.circle.badge.checkmark",
                readiness: model.contactsReadiness,
                status: model.health(for: .contacts),
                detail: "Contacts help Nudge show names instead of phone numbers or email addresses.",
                primaryTitle: "Request Contacts",
                primarySystemImage: "person.2",
                primaryDisabled: !model.canRequestContacts,
                helperText: model.contactsNextAction,
                action: { model.request(.contacts) }
            )

            SetupPathBox(lines: [
                "Nudge imports read-only copies into its local cache.",
                "Contacts are optional. Without Contacts, Nudge can still work.",
                "After the first import, the Refresh button updates Messages and alerts."
            ])
        }
    }
}

private struct PermissionStep: View {
    var title: String
    var subtitle: String
    var health: PermissionHealth
    var primaryTitle: String
    var primarySystemImage: String
    var request: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: title, subtitle: subtitle)
            PermissionCard(
                health: health,
                detail: health.detail,
                primaryTitle: primaryTitle,
                primarySystemImage: primarySystemImage,
                primaryAction: request,
                secondaryTitle: "Open System Settings",
                secondaryAction: openSettings
            )
        }
    }
}

private struct CloudAIStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "AI",
                subtitle: "Local suggestions stay on by default. Gemini is optional and only used after you save a key and turn Cloud AI on."
            )

            PermissionCard(
                health: model.health(for: .cloudAI),
                detail: model.hasGeminiConfig ? "Gemini credentials were detected. Enable cloud AI only if you are comfortable sending selected Messages snippets for structured suggestions." : "No Gemini credentials were detected. Local suggestions remain active.",
                primaryTitle: "Check Credentials",
                primarySystemImage: "arrow.clockwise",
                primaryAction: { model.refreshPermissions() },
                secondaryTitle: nil,
                secondaryAction: nil
            )

            SettingsCard(tint: model.health(for: .cloudAI).state.tint) {
                Text("Gemini Setup")
                    .font(.headline)

                SecureField("Gemini API key", text: $model.geminiAPIKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                TextField("Model", text: $model.geminiModelInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text(model.geminiInputValidation.userFacingMessage)
                    .font(.caption)
                    .foregroundStyle(model.geminiInputValidation.isValid ? Color.secondary : Color.orange)

                Button {
                    model.saveGeminiConfig()
                } label: {
                    Label("Save Gemini Setup", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSaveGeminiConfig)
            }

            Toggle("Enable Cloud AI suggestions", isOn: $model.profile.cloudAIEnabled)
                .toggleStyle(.switch)
                .disabled(!model.hasGeminiConfig)

            Text(model.hasGeminiConfig ? "Gemini will only be used after this toggle is on and setup is saved." : "Local fallback suggestions remain active without credentials.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PrivacyStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Privacy",
                subtitle: "Nudge keeps imported Messages and generated suggestions in a local SQLite database for this alpha."
            )

            SetupPathBox(lines: [
                "Imported Messages are stored locally so the queue can show evidence and avoid duplicates.",
                "The alpha database is not encrypted yet. Delete local data before sharing or returning a test machine.",
                "Cloud AI is off unless you save Gemini credentials and enable the toggle in AI settings."
            ])

            SettingsCard(tint: Color.red) {
                Text("Local Data")
                    .font(.headline)
                Button("Delete Generated Suggestions") {
                    model.clearGeneratedSuggestions()
                }
                Button("Delete Imported Messages Cache", role: .destructive) {
                    model.clearImportedConversationCache()
                }
                Button("Delete All Local Nudge Data", role: .destructive) {
                    model.eraseAllData()
                }
            }
            .controlSize(.small)
        }
    }
}

#if NUDGE_INTERNAL_DIAGNOSTICS
private struct DiagnosticsSettingsStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Diagnostics",
                subtitle: "Diagnostics report counts, health states, and a temporary local Messages decode trace."
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        model.runAppleMessagesDecodeTrace()
                    } label: {
                        Label("Run Mom/Hunter Trace", systemImage: "text.magnifyingglass")
                    }
                    .disabled(model.isWorking)

                    Button {
                        model.runAppleMessagesTextDiagnostic()
                    } label: {
                        Label("Check Messages Text", systemImage: "text.bubble")
                    }
                    .disabled(model.isWorking)

                    Button("Clear Diagnostics") {
                        model.clearGeminiDiagnostics()
                    }
                    .disabled(model.isWorking)
                }
                .controlSize(.small)

                if let report = model.appleMessagesDecodeTraceReport {
                    OnboardingMessagesDecodeTraceView(report: report)
                }

                if let diagnostics = model.appleMessagesTextDiagnostics {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Messages Text Check")
                            .font(.headline)
                        Text("Since \(diagnostics.checkedSince.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(diagnostics.outgoingWithPlainText) sent rows have plain text. \(diagnostics.recoveredOutgoingWithoutPlainTextCount) sent rows can be recovered from alternate message payloads. \(diagnostics.outgoingUnresolvedAfterDecode) sent rows are still unresolved.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if model.appleMessagesDecodeTraceReport == nil {
                    Text("Run the Mom/Hunter trace after granting Full Disk Access to see exactly where each outgoing body is stored. Snippets stay in memory and are not written to Nudge storage.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }
}

private struct OnboardingMessagesDecodeTraceView: View {
    var report: AppleMessagesDecodeTraceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Messages Decode Trace", systemImage: "text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text(report.checkedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("\(report.threadMatches.count) chat matches. \(report.outgoingRowCount) sent rows. \(report.placeholderRowCount) placeholders.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !report.unmatchedTitles.isEmpty {
                Text("No matching chat title or contact-resolved participant found for \(report.unmatchedTitles.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(report.threadMatches) { thread in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(thread.chatTitle) · \(thread.chatKind.displayName)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(thread.outgoingRows.count) sent")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(thread.chatGUID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if thread.outgoingRows.isEmpty {
                        Text("No outgoing rows found since \(report.checkedSince.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(thread.outgoingRows) { row in
                            OnboardingMessagesDecodeTraceRowView(row: row)
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Temporary local trace only. Snippets are not written to Nudge storage or files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingMessagesDecodeTraceRowView: View {
    var row: AppleMessagesDecodeTraceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(row.failureReason == nil ? "Readable" : "Placeholder", systemImage: row.failureReason == nil ? "checkmark.bubble" : "exclamationmark.bubble")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(row.failureReason == nil ? .green : .red)
                Text(row.sentAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(row.messageGUID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            OnboardingTraceLine(title: "message.text", value: messageTextValue)
            OnboardingTraceLine(title: "attributedBody", value: blobValue(row.attributedBody))
            OnboardingTraceLine(title: "payload_data", value: blobValue(row.payloadData))
            OnboardingTraceLine(title: "summary_info", value: blobValue(row.messageSummaryInfo))
            OnboardingTraceLine(title: "final body", value: row.finalBody)
            if let failureReason = row.failureReason {
                OnboardingTraceLine(title: "failure", value: failureReason, tint: .red)
            }
        }
        .padding(.vertical, 4)
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

    private func blobValue(_ trace: AppleMessagesBlobDecodeTrace) -> String {
        guard trace.isPresent else {
            return "missing"
        }
        var parts = ["present, \(trace.byteLength) bytes"]
        if let prefix = trace.hexPrefix {
            parts.append("prefix: \(prefix)")
        }
        if let decodedSnippet = trace.decodedSnippet {
            parts.append("decoded: \(decodedSnippet)")
        } else {
            parts.append("decoded: none")
        }
        return parts.joined(separator: " | ")
    }
}

private struct OnboardingTraceLine: View {
    var title: String
    var value: String
    var tint: Color?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(tint ?? .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
#endif

private struct AboutStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "How Nudge Works",
                subtitle: "Nudge turns recent Messages into a small queue of conversations that may need your attention."
            )

            VStack(alignment: .leading, spacing: 14) {
                GuideSection(
                    systemImage: "message.badge",
                    title: "1. Connect Messages",
                    detail: "Nudge reviews recent Apple Messages locally and looks for conversations with unanswered questions, deadlines, reminders, or follow-ups."
                )
                GuideSection(
                    systemImage: "arrow.clockwise",
                    title: "2. Refresh the queue",
                    detail: "Use Refresh whenever you want to recheck Messages. Nudge also refreshes in the background and replaces older active alerts when newer messages matter."
                )
                GuideSection(
                    systemImage: "checkmark.circle",
                    title: "3. Mark alerts done",
                    detail: "Open the queue, review the message context, then mark the alert done when that conversation no longer needs action."
                )
                GuideSection(
                    systemImage: "bell.badge",
                    title: "When notifications appear",
                    detail: "Notifications appear only for genuinely new alerts when notifications are allowed. Set cadence to Quiet if you do not want system notifications."
                )
                GuideSection(
                    systemImage: "cloud",
                    title: "Local mode works without Gemini credentials",
                    detail: "If you save Gemini credentials and enable Cloud AI, selected message snippets may be sent to Gemini to improve alert ranking."
                )
            }
        }
    }
}

private struct SummaryStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: "Setup summary",
                subtitle: "You can finish with missing optional permissions. Nudge will keep showing degraded states honestly."
            )

            VStack(spacing: 10) {
                ForEach([PermissionKind.fullDiskAccess, .appleMessages, .contacts], id: \.rawValue) { kind in
                    PermissionSummaryRow(health: model.health(for: kind))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Sources")
                    .font(.headline)
                SourceSummaryRow(
                    title: "Apple Messages",
                    systemImage: "message",
                    readiness: model.messagesReadiness,
                    health: model.health(for: .appleMessages),
                    source: model.source(for: .appleMessages),
                    importResult: model.lastImportResults[.appleMessages]
                )
            }

            Text("Messages is the prototype source. Contacts are optional and only improve display names.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct StepHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PrincipleRow: View {
    @Environment(\.nudgePalette) private var palette

    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SourceSetupCard: View {
    var title: String
    var systemImage: String
    var readiness: OnboardingReadinessState?
    var status: PermissionHealth
    var detail: String
    var primaryTitle: String?
    var primarySystemImage: String?
    var primaryDisabled = false
    var helperText: String?
    var action: (() -> Void)?

    var body: some View {
        SettingsCard(tint: status.state.tint) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let readiness {
                        ReadinessPill(readiness: readiness)
                    }
                    HealthStatusPill(health: status)
                    Spacer(minLength: 0)
                }
            }

            Text(detail)
                .foregroundStyle(SettingsSurface.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let primaryTitle, let primarySystemImage, let action {
                Button(action: action) {
                    Label(primaryTitle, systemImage: primarySystemImage)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(primaryDisabled)
            }

            if let helperText {
                Text(helperText)
                    .font(.caption)
                    .foregroundStyle(SettingsSurface.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionCard: View {
    var health: PermissionHealth
    var detail: String
    var primaryTitle: String
    var primarySystemImage: String
    var primaryAction: () -> Void
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    var primaryDisabled = false
    var helperText: String?

    var body: some View {
        SettingsCard(tint: health.state.tint) {
            HStack {
                Label(health.kind.displayName, systemImage: health.kind.systemImage)
                    .font(.headline)
                Spacer()
                HealthStatusPill(health: health)
            }

            Text(detail)
                .foregroundStyle(SettingsSurface.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(action: primaryAction) {
                    Label(primaryTitle, systemImage: primarySystemImage)
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
            .controlSize(.small)

            if let helperText {
                Text(helperText)
                    .font(.caption)
                    .foregroundStyle(SettingsSurface.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionSummaryRow: View {
    var health: PermissionHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
            Image(systemName: health.kind.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(health.state.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health.kind.displayName)
                        .font(.callout.weight(.medium))
                    Text(health.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack {
                HealthStatusPill(health: health)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(SettingsSurface.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(health.state.tint.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SourceSummaryRow: View {
    var title: String
    var systemImage: String
    var readiness: OnboardingReadinessState
    var health: PermissionHealth
    var source: ConversationSource?
    var importResult: ImportResult?
    var showsHealth = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(health.state.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ReadinessPill(readiness: readiness)
                if showsHealth {
                    HealthStatusPill(health: health)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(SettingsSurface.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(health.state.tint.opacity(0.12), lineWidth: 1)
        }
    }

    private var detail: String {
        if let importResult {
            return "Last import added \(importResult.insertedMessages), skipped \(importResult.skippedMessages)."
        }
        if let lastSyncAt = source?.lastSyncAt {
            return "Last synced \(summaryRelativeLabel(lastSyncAt))."
        }
        return health.detail
    }
}

private struct SetupPathBox: View {
    @Environment(\.nudgePalette) private var palette

    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(palette.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct ReadinessPill: View {
    var readiness: OnboardingReadinessState

    var body: some View {
        Label(readiness.rawValue, systemImage: readiness.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(readiness.tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(readiness.tint.opacity(0.12), in: Capsule())
    }
}

private struct HealthStatusPill: View {
    var health: PermissionHealth

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(health.state.tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(health.state.tint.opacity(0.12), in: Capsule())
    }

    private var title: String {
        guard health.kind == .notifications else {
            return health.state.displayName
        }

        switch health.state {
        case .available:
            return "Enabled"
        case .missing:
            return "Not enabled"
        case .degraded:
            return "Needs check"
        case .revoked:
            return "Off"
        case .unsupported:
            return "Unavailable"
        }
    }

    private var systemImage: String {
        guard health.kind == .notifications else {
            return health.state.systemImage
        }

        switch health.state {
        case .available:
            return "checkmark.circle.fill"
        case .missing:
            return "bell.badge"
        case .degraded:
            return "questionmark.circle.fill"
        case .revoked, .unsupported:
            return "xmark.circle.fill"
        }
    }
}

private struct OperationalStatusSidebarView: View {
    var status: NudgeOperationalStatus

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(status.state.tint)
                .frame(width: 22, height: 5)
            Label(status.shortTitle, systemImage: status.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.state.tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize(horizontal: true, vertical: false)
        .background(status.state.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(status.state.tint.opacity(0.20), lineWidth: 1)
        }
        .help(status.detail)
    }
}

private struct GuideSection: View {
    @Environment(\.nudgePalette) private var palette

    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        SettingsCard(tint: palette.primary) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .foregroundStyle(SettingsSurface.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private func timeLabel(_ minutes: Int) -> String {
    let normalized = ((minutes % 1440) + 1440) % 1440
    let hour = normalized / 60
    let minute = normalized % 60
    let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    return TimeFormatters.hour.string(from: date)
}

private func summaryRelativeLabel(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func recheckStatusTitle(for step: OnboardingStep) -> String {
    switch step {
    case .messages:
        return "Check Messages Access"
    case .notifications:
        return "Check Notifications"
    case .status:
        return "Recheck Status"
    default:
        return "Check Status"
    }
}

private enum TimeFormatters {
    static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private extension PermissionKind {
    var systemImage: String {
        switch self {
        case .fullDiskAccess: return "internaldrive"
        case .appleMessages: return "message"
        case .contacts: return "person.crop.circle"
        case .notifications: return "bell"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .cloudAI: return "cloud"
        }
    }
}

private extension HealthState {
    var displayName: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Missing"
        case .degraded: return "Degraded"
        case .revoked: return "Revoked"
        case .unsupported: return "Unsupported"
        }
    }

    var systemImage: String {
        switch self {
        case .available: return "checkmark.circle"
        case .missing: return "minus.circle"
        case .degraded: return "exclamationmark.circle"
        case .revoked: return "xmark.circle"
        case .unsupported: return "slash.circle"
        }
    }

    var tint: Color {
        switch self {
        case .available: return .green
        case .missing, .degraded: return .orange
        case .revoked: return .red
        case .unsupported: return .secondary
        }
    }
}

private extension OnboardingReadinessState {
    var systemImage: String {
        switch self {
        case .ready:
            return "play.circle"
        case .needsSetup:
            return "wrench.and.screwdriver"
        case .needsPermission:
            return "lock.open"
        case .connected:
            return "link.circle"
        case .imported:
            return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ready, .connected:
            return .blue
        case .needsSetup, .needsPermission:
            return .orange
        case .imported:
            return .green
        }
    }
}
