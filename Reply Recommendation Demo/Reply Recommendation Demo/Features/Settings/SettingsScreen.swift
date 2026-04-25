import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SettingsNavigationRow(
                        title: "Reply Settings",
                        subtitle: "\(settingsStore.backendMode.displayName) backend, \(settingsStore.defaultTone.displayName.lowercased()) tone",
                        systemImage: "text.bubble"
                    ) {
                        ReplySettingsView(viewModel: viewModel)
                    }

                    SettingsNavigationRow(
                        title: "Local Model & LoRA",
                        subtitle: localModelSubtitle,
                        systemImage: "cpu"
                    ) {
                        LocalModelLoraSettingsView()
                    }

                    SettingsNavigationRow(
                        title: "Local Training",
                        subtitle: trainingSubtitle,
                        systemImage: "chart.line.uptrend.xyaxis"
                    ) {
                        LocalTrainingSettingsView(settingsStore: settingsStore)
                    }

                    SettingsNavigationRow(
                        title: "Cloud",
                        subtitle: "\(settingsStore.cloudProvider.displayName) fallback",
                        systemImage: "cloud"
                    ) {
                        CloudSettingsView(viewModel: viewModel)
                    }

                    SettingsNavigationRow(
                        title: "Thread",
                        subtitle: "Current user and reply style",
                        systemImage: "person.2"
                    ) {
                        ThreadSettingsView(viewModel: viewModel)
                    }

                    SettingsNavigationRow(
                        title: "Privacy",
                        subtitle: "Local data and demo limits",
                        systemImage: "lock.shield"
                    ) {
                        PrivacySettingsView()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: settingsStore.backendMode) { _, _ in
                viewModel.refreshEngineStatus()
            }
            .onChange(of: settingsStore.cloudProvider) { _, _ in
                viewModel.refreshEngineStatus()
            }
            .onChange(of: settingsStore.cloudAPIKey) { _, _ in
                viewModel.refreshEngineStatus()
            }
            .onChange(of: settingsStore.loraAdapterEnabled) { _, _ in
                viewModel.refreshEngineStatus()
            }
            .onChange(of: settingsStore.userTrainedLoraAdapterEnabled) { _, _ in
                viewModel.refreshEngineStatus()
            }
            .onChange(of: settingsStore.userTrainedLoraAdapterPath) { _, _ in
                viewModel.refreshEngineStatus()
            }
            .task {
                viewModel.refreshEngineStatus()
            }
        }
        .presentationDetents([.large])
    }

    private var localModelSubtitle: String {
        if settingsStore.userTrainedLoraAdapterEnabled {
            return "Private LoRA enabled"
        }
        if settingsStore.loraAdapterEnabled {
            return "Bundled LoRA enabled"
        }
        return settingsStore.bundledLlamaModel.displayName
    }

    private var trainingSubtitle: String {
        if let completedAt = settingsStore.lastTrainingCompletedAt {
            return "Last run \(completedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return settingsStore.localTrainingEnabled ? "Ready for on-device training" : "Off"
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
            }
            .padding(.vertical, 3)
        }
    }
}

private struct ReplySettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            Section("Backend") {
                Picker("Suggestion backend", selection: $settingsStore.backendMode) {
                    ForEach(settingsStore.availableBackendModes) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.engineStatusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Safe demo fallback to Mock", isOn: $settingsStore.safeDemoModeEnabled)

                if settingsStore.isRunningInXcodePreview {
                    Text("Xcode Previews skip Local GGUF inference. Use Simulator or a device for Local mode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Default Reply Style") {
                Picker("Tone", selection: $settingsStore.defaultTone) {
                    ForEach(ReplyToneOption.allCases) { tone in
                        Text(tone.displayName).tag(tone)
                    }
                }

                Picker("Length", selection: $settingsStore.defaultLength) {
                    ForEach(ReplyLengthOption.allCases) { length in
                        Text(length.displayName).tag(length)
                    }
                }
            }
        }
        .navigationTitle("Reply Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalModelLoraSettingsView: View {
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            if settingsStore.availableBackendModes.contains(.local) {
                Section("Model") {
                    Picker("Bundled GGUF", selection: $settingsStore.bundledLlamaModel) {
                        ForEach(BundledLlamaModelOption.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    Text("Applies when Backend is Local. Switching model reloads the local engine on the next generation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("LoRA") {
                    Toggle(isOn: $settingsStore.loraAdapterEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reply SFT LoRA")
                            Text("Bundled adapter for social replies")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!settingsStore.bundledLlamaModel.supportsReplyLoRA)

                    Toggle(
                        isOn: Binding(
                            get: { settingsStore.userTrainedLoraAdapterEnabled },
                            set: { settingsStore.userTrainedLoraAdapterEnabled = $0 }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Private LoRA")
                            Text(privateLoraDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!settingsStore.userTrainedLoraAdapterAvailable)

                    if let completedAt = settingsStore.lastTrainingCompletedAt {
                        LabeledContent("Last trained", value: completedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let loss = settingsStore.lastTrainingFinalLoss {
                        LabeledContent("Final loss", value: loss.formatted(.number.precision(.fractionLength(4))))
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Local model unavailable",
                        systemImage: "cpu",
                        description: Text("Local model controls are hidden in this runtime.")
                    )
                }
            }
        }
        .navigationTitle("Local Model & LoRA")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var privateLoraDescription: String {
        settingsStore.userTrainedLoraAdapterAvailable
            ? "Use the adapter created by on-device training"
            : "Run local training before enabling"
    }
}

private struct LocalTrainingSettingsView: View {
    @ObservedObject private var settingsStore: AppSettingsStore
    @StateObject private var trainingViewModel: TrainingSettingsViewModel
    @State private var isShowingOnboarding = false

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        _trainingViewModel = StateObject(
            wrappedValue: TrainingSettingsViewModel(
                settingsStore: settingsStore,
                trainingService: LLMTrainingService()
            )
        )
    }

    var body: some View {
        Form {
            Section("Local Training") {
                Toggle(
                    "Enable on-device training",
                    isOn: Binding(
                        get: { settingsStore.localTrainingEnabled },
                        set: { newValue in
                            settingsStore.localTrainingEnabled = newValue
                            if newValue && !settingsStore.localTrainingOnboardingCompleted {
                                isShowingOnboarding = true
                            }
                        }
                    )
                )

                Button("Learn about local training") {
                    isShowingOnboarding = true
                }
            }

            if settingsStore.localTrainingEnabled {
                TrainingReadinessChecklist()

                Section {
                    TrainingStatusCard(viewModel: trainingViewModel)
                }

                Section {
                    Button {
                        Task { await trainingViewModel.startTraining() }
                    } label: {
                        Label(
                            trainingViewModel.status.isActive ? "Training in progress" : "Start Training",
                            systemImage: "play.circle"
                        )
                    }
                    .disabled(trainingViewModel.status.isActive)
                }

                TrainingLogsView(logs: trainingViewModel.recentLogs)
            }
        }
        .navigationTitle("Local Training")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingOnboarding) {
            TrainingOnboardingView {
                settingsStore.localTrainingOnboardingCompleted = true
            }
        }
    }
}

private struct CloudSettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            Section("Cloud Fallback") {
                Picker("Provider", selection: $settingsStore.cloudProvider) {
                    ForEach(CloudProviderOption.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                TextField("Custom model name (optional)", text: $settingsStore.cloudModelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("API key", text: $settingsStore.cloudAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Cloud mode is a dev fallback. Local mode keeps generation on-device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Text(viewModel.engineStatusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cloud")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThreadSettingsView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Form {
            Section("Thread") {
                Picker(
                    "Current user",
                    selection: Binding(
                        get: { viewModel.activeComposerParticipantID },
                        set: { viewModel.setActiveComposerParticipant($0) }
                    )
                ) {
                    ForEach(viewModel.participants, id: \.id) { participant in
                        Text(viewModel.displayName(for: participant.id))
                            .tag(participant.id)
                    }
                }

                Picker("Thread tone", selection: $viewModel.threadToneOverride) {
                    ForEach(ThreadToneOverride.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Picker("Thread length", selection: $viewModel.threadLengthOverride) {
                    ForEach(ThreadLengthOverride.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
        }
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacySettingsView: View {
    var body: some View {
        Form {
            Section("Privacy") {
                Label("No screen scraping or keyboard extension permissions are required for this demo.", systemImage: "lock.shield")
                Label("Local mode runs against bundled GGUF files when available.", systemImage: "iphone")
                Label("Training output stays in the app sandbox unless you export it separately.", systemImage: "folder.badge.person.crop")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TrainingReadinessChecklist: View {
    var body: some View {
        Section("Before You Start") {
            Label("Connect power before training.", systemImage: "powerplug")
            Label("Keep the app open and avoid locking the device.", systemImage: "iphone.gen3.radiowaves.left.and.right")
            Label("Stop if the device gets uncomfortably warm.", systemImage: "thermometer.medium")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct TrainingStatusCard: View {
    @ObservedObject var viewModel: TrainingSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                TrainingProgressRing(
                    progress: viewModel.progress,
                    status: viewModel.status,
                    percentText: viewModel.progressPercentText
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.status.displayName)
                        .font(.headline)
                    Text(viewModel.runID ?? "No active run")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Elapsed \(viewModel.elapsedText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TrainingMetricsGrid(
                latestStep: viewModel.latestStep,
                report: viewModel.report
            )

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let report = viewModel.report, report.success {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Adapter saved")
                        .font(.subheadline.weight(.semibold))
                    Text(report.outputAdapterPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TrainingProgressRing: View {
    let progress: Double?
    let status: TrainingRunStatus
    let percentText: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 8)

            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: status.isActive ? 0.68 : 0)
                    .stroke(Color.accentColor.opacity(status.isActive ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            Text(status.isActive || progress != nil ? percentText : "--")
                .font(.caption.weight(.bold))
                .monospacedDigit()
        }
        .frame(width: 72, height: 72)
        .accessibilityLabel("Training progress")
        .accessibilityValue(percentText)
    }
}

struct TrainingMetricsGrid: View {
    let latestStep: LLMTrainingStepMetric?
    let report: LLMTrainingReport?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            TrainingMetricCell(title: "Loss", value: lossText)
            TrainingMetricCell(title: "Memory", value: memoryText)
            TrainingMetricCell(title: "Thermal", value: latestStep?.thermalState ?? report?.thermalSamples.last?.state ?? "--")
            TrainingMetricCell(title: "App State", value: latestStep?.appState ?? report?.appStateEvents.last?.state ?? "--")
            TrainingMetricCell(title: "Protected Data", value: protectedDataText)
            TrainingMetricCell(title: "Main Stalls", value: "\(report?.mainThreadStalls.count ?? 0)")
        }
    }

    private var lossText: String {
        if let loss = latestStep?.loss ?? report?.stepMetrics.last?.loss {
            return loss.formatted(.number.precision(.fractionLength(4)))
        }
        return "--"
    }

    private var memoryText: String {
        let value = latestStep?.memoryMB ?? report?.peakMemoryMB
        guard let value else { return "--" }
        return "\(Int(value.rounded())) MB"
    }

    private var protectedDataText: String {
        guard let value = latestStep?.protectedDataAvailable ?? report?.appStateEvents.last?.protectedDataAvailable else {
            return "--"
        }
        return value ? "Available" : "Unavailable"
    }
}

private struct TrainingMetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct TrainingLogsView: View {
    let logs: [String]

    var body: some View {
        Section("Recent Logs") {
            if logs.isEmpty {
                Text("Logs will appear when training starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                    Text(log)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TrainingOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TrainingOnboardingRow(
                        title: "What training does",
                        text: "Local training creates a small private LoRA adapter that can make replies closer to your own style.",
                        systemImage: "wand.and.sparkles"
                    )
                    TrainingOnboardingRow(
                        title: "What stays local",
                        text: "Training samples and the adapter are handled in the app sandbox. Use the adapter path returned by the training report.",
                        systemImage: "lock"
                    )
                    TrainingOnboardingRow(
                        title: "What to watch",
                        text: "Keep the device plugged in, keep the app open, and avoid locking or backgrounding while training runs.",
                        systemImage: "exclamationmark.triangle"
                    )
                    TrainingOnboardingRow(
                        title: "What can fail",
                        text: "Very short data, model loading, memory pressure, or save errors can fail a run. Settings will show the error code and recent logs.",
                        systemImage: "stethoscope"
                    )
                }
            }
            .navigationTitle("Local Training")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onComplete()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct TrainingOnboardingRow: View {
    let title: String
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let settingsStore = AppSettingsStore()
    return SettingsScreen(
        viewModel: ChatViewModel(
            settingsStore: settingsStore,
            chatService: DemoChatService.shared
        )
    )
    .environmentObject(settingsStore)
}
