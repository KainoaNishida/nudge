import SwiftUI
import MinderCore

@MainActor
final class ManagedAISettingsModel: ObservableObject {
    @Published var goalText = ""
    @Published var historyDays = ManagedLocalState.defaultHistoryWindowDays
    @Published var email = ""
    @Published var code = ""
    @Published var consent = false
    @Published var state = ManagedLocalState()
    @Published var message = ""
    @Published var working = false
    private let store: MinderStore
    private let onChange: @MainActor () -> Void
    init(store: MinderStore, onChange: @escaping @MainActor () -> Void) { self.store = store; self.onChange = onChange; reload() }
    var configured: Bool { ManagedServiceConfiguration.configured() != nil }
    func reload() {
        do { state = try store.managedState(); goalText = state.goal.text; historyDays = state.historyWindowDays; consent = state.consentVersion == 1 }
        catch { message = error.localizedDescription }
    }
    func saveGoal() {
        do { try store.saveGoal(goalText); reload(); message = "Goal saved. Nudge will reassess your conversations."; onChange() }
        catch { message = error.localizedDescription }
    }
    func saveHistoryWindow() {
        do { try store.saveHistoryWindowDays(historyDays); reload(); message = "History window saved. Refresh to reassess recent conversations."; onChange() }
        catch { message = error.localizedDescription }
    }
    func localOnly() {
        do {
            try store.updateManagedState { $0.mode = .local; $0.revision += 1 }
            if var profile = try store.fetchUserProfile() { profile.cloudAIEnabled = false; try store.saveUserProfile(profile) }
            reload(); onChange()
        } catch { message = error.localizedDescription }
    }
    func enableManaged() {
        guard consent, state.accountId != nil else { return }
        do { try store.updateManagedState { $0.mode = .managed; $0.consentVersion = 1; $0.revision += 1 }; reload(); onChange(); message = "Managed AI enabled. Refresh the queue to begin." }
        catch { message = error.localizedDescription }
    }
    func requestCode() { run { client in try await client.requestCode(email: self.email); self.message = "If this email has an invitation, a sign-in code is on its way." } }
    func verifyCode() {
        run { client in
            let id = try await client.verifyCode(email: self.email, code: self.code)
            let status = try await client.status()
            guard status.access else { try await client.signOut(); throw ManagedAIError.unavailable("This account does not have an alpha invitation.") }
            try self.store.updateManagedState { state in
                if let previous = state.cacheAccountId ?? state.accountId, previous != id {
                    let goal = state.goal, historyDays = state.historyWindowDays
                    state = ManagedLocalState(); state.goal = goal; state.historyWindowDays = historyDays
                }
                state.accountId = id; state.cacheAccountId = id; state.revision += 1; state.status = status
            }
            self.code = ""; self.message = "Signed in. Review the disclosure and enable managed AI."; self.reload(); self.onChange()
        }
    }
    func signOut() {
        run { client in
            try await client.signOut()
            try self.store.updateManagedState { $0.accountId = nil; $0.revision += 1; $0.consentVersion = 0; $0.coverage.detail = "Signed out. Previous recommendations are retained." }
            self.reload(); self.onChange(); self.message = "Signed out."
        }
    }
    func deleteAccount() {
        run { client in
            try await client.deleteAccount()
            try self.store.updateManagedState { $0.accountId = nil; $0.consentVersion = 0; $0.revision += 1; $0.status = nil }
            self.reload(); self.onChange(); self.message = "Managed access and backend account data deleted. Local history remains until you delete it in Privacy settings."
        }
    }
    func unmute(_ id: String) {
        do { try store.unmuteManagedThread(id); reload(); onChange() } catch { message = error.localizedDescription }
    }
    private func run(_ action: @escaping (ManagedAIClient) async throws -> Void) {
        guard !working, let configuration = ManagedServiceConfiguration.configured() else { message = "This build needs the owner's managed service configuration."; return }
        working = true
        Task { @MainActor in
            defer { self.working = false }
            do { try await action(ManagedAIClient(configuration: configuration)) } catch { self.message = error.localizedDescription }
        }
    }
}

struct ManagedAISettingsView: View {
    @ObservedObject var model: ManagedAISettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Messages history for AI").font(.headline)
            Text("Nudge checks conversations active within this many days. A shorter window sends fewer conversations to Gemini, but may miss older follow-ups.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Last")
                TextField("Days", value: $model.historyDays, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 68)
                Text("days")
                Stepper("History window", value: $model.historyDays, in: ManagedLocalState.allowedHistoryWindowDays)
                    .labelsHidden()
                Spacer()
                Button("Save history window") { model.saveHistoryWindow() }
                    .disabled(!ManagedLocalState.allowedHistoryWindowDays.contains(model.historyDays) || model.historyDays == model.state.historyWindowDays)
            }
            Text("Choose 7–180 days; the default is 50. Saving hides older AI queue items immediately. Refresh applies the new window to analysis. Done history stays available.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("What would you like Nudge to help with?").font(.headline)
            Text("Optional. Your goal guides priorities while clear obligations still receive attention.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.goalText).font(.body).frame(minHeight: 72, maxHeight: 110).border(Color.secondary.opacity(0.25))
            HStack {
                ForEach(["Keep up with friends", "Follow through on commitments", "Review incoming conversations"], id: \.self) { example in
                    Button(example) { model.goalText = example }.font(.caption)
                }
            }
            HStack {
                Text("\(model.goalText.count)/2,000").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save goal") { model.saveGoal() }.disabled(model.goalText.count > 2_000)
            }
            Divider()
            Text("AI mode").font(.headline)
            HStack {
                Button("Use local-only compatibility mode") { model.localOnly() }
                Text(model.state.mode == .local ? "Selected" : "").font(.caption)
            }
            Text("Managed AI · Invited alpha").font(.headline)
            if !model.configured {
                Text("This build is waiting for the owner's development or alpha service configuration.").font(.callout).foregroundStyle(.secondary)
            } else if model.state.accountId == nil {
                TextField("Invited email address", text: $model.email).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Email a sign-in code") { model.requestCode() }.disabled(model.email.isEmpty || model.working)
                    TextField("6-digit code", text: $model.code).textFieldStyle(.roundedBorder).frame(width: 110)
                    Button("Sign in") { model.verifyCode() }.disabled(model.code.count != 6 || model.working)
                }
            } else {
                if let status = model.state.status {
                    Text("$\(status.remainingUSD, specifier: "%.2f") AI allowance remaining · Resets \(status.resetsAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }
                HStack {
                    Button("Sign out") { model.signOut() }
                    Button("Delete managed account", role: .destructive) { model.deleteAccount() }
                }.disabled(model.working)
            }
            Text("Managed AI sends your goal, contact display names, up to 8 recent messages per conversation within your chosen history window (up to 80 total if more context is needed), local activity statistics, and conversation feedback through Nudge's backend to paid Gemini. Message text may contain personal information. Attachments and Messages routing identifiers stay on this Mac. Nudge's backend keeps access and usage metadata, but does not store messages, goals, or explanations. Gemini requests disable stored interaction objects; provider operational retention may still apply.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("I agree to this managed AI data flow (version 1)", isOn: $model.consent)
            Button(model.state.mode == .managed ? "Managed AI enabled" : "Enable managed AI") { model.enableManaged() }
                .disabled(!model.consent || model.state.accountId == nil || model.working)
            Text("The owner funds up to $5 of AI usage per UTC month. When the allowance is used, Nudge keeps your queue and pauses analysis.").font(.caption).foregroundStyle(.secondary)
            let muted = model.state.threads.values.filter(\.muted).sorted { $0.snapshot.title < $1.snapshot.title }
            if !muted.isEmpty {
                Divider(); Text("Muted conversations").font(.headline)
                ForEach(muted, id: \.snapshot.threadId) { thread in
                    HStack { Text(thread.localDisplayTitle ?? thread.snapshot.title); Spacer(); Button("Unmute") { model.unmute(thread.snapshot.threadId) } }
                }
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled) }
        }.onAppear { model.reload() }
    }
}
