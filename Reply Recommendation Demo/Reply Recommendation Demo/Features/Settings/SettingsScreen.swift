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

                    Toggle(isOn: $settingsStore.localInlineCompletionEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inline ghost completion")
                            Text("Gray continuation after your draft uses this same model (no extra load).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
    @State private var isShowingTrainingCover = false
    @State private var suppressActiveTrainingPresentation = false

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
        LocalTrainingScreen(
            settingsStore: settingsStore,
            trainingViewModel: trainingViewModel,
            isShowingOnboarding: $isShowingOnboarding,
            isShowingTrainingCover: $isShowingTrainingCover,
            suppressActiveTrainingPresentation: $suppressActiveTrainingPresentation
        )
        .navigationTitle("Local Training")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingOnboarding) {
            TrainingOnboardingView {
                settingsStore.localTrainingOnboardingCompleted = true
            }
        }
        .fullScreenCover(isPresented: $isShowingTrainingCover) {
            TrainingFullScreenCover(
                viewModel: trainingViewModel,
                onExit: {
                    suppressActiveTrainingPresentation = true
                    trainingViewModel.cancelTraining()
                    isShowingTrainingCover = false
                }
            )
        }
        .onChange(of: trainingViewModel.status) { _, status in
            if status.isActive && !suppressActiveTrainingPresentation {
                isShowingTrainingCover = true
            }
        }
    }
}

struct LocalTrainingScreen: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var trainingViewModel: TrainingSettingsViewModel
    @Binding var isShowingOnboarding: Bool
    @Binding var isShowingTrainingCover: Bool
    @Binding var suppressActiveTrainingPresentation: Bool

    var body: some View {
        Form {
            Section {
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
            }

            Section {
                Button {
                    startTraining()
                } label: {
                    HStack {
                        Spacer()
                        Text(trainingViewModel.status.isActive ? "Training in Progress" : "Start Training")
                            .font(.headline)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!settingsStore.localTrainingEnabled || trainingViewModel.status.isActive)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                Button("Learn about local training") {
                    isShowingOnboarding = true
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if trainingViewModel.status == .completed || trainingViewModel.status == .failed || trainingViewModel.status == .cancelled {
                Section("Last Run") {
                    CompactTrainingResultView(viewModel: trainingViewModel)
                }
            }
        }
    }

    private func startTraining() {
        suppressActiveTrainingPresentation = false
        isShowingTrainingCover = true
        Task { await trainingViewModel.startTraining() }
    }
}

private struct CompactTrainingResultView: View {
    @ObservedObject var viewModel: TrainingSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                titleText,
                systemImage: systemImage
            )
            .font(.subheadline.weight(.semibold))

            if let report = viewModel.report {
                LabeledContent("Duration", value: durationText(report.durationMs))
                if let loss = report.stepMetrics.last?.loss {
                    LabeledContent("Final loss", value: loss.formatted(.number.precision(.fractionLength(4))))
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .font(.footnote)
    }

    private func durationText(_ durationMs: Double) -> String {
        let seconds = Int((durationMs / 1000).rounded())
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }

    private var titleText: String {
        switch viewModel.status {
        case .completed: return "Training completed"
        case .cancelled: return "Training cancelled"
        default: return "Training failed"
        }
    }

    private var systemImage: String {
        switch viewModel.status {
        case .completed: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        default: return "exclamationmark.triangle"
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

struct TrainingFullScreenCover: View {
    @ObservedObject var viewModel: TrainingSettingsViewModel
    let onExit: () -> Void
    @State private var isDimmed = false
    @State private var isShowingDetails = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDimmed {
                DimmedTrainingView(viewModel: viewModel)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDimmed = false
                        }
                    }
            } else {
                VStack(spacing: 0) {
                    TrainingFullScreenHeader(
                        onDim: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isDimmed = true
                            }
                        },
                        onExit: onExit
                    )

                    Spacer(minLength: 36)

                    ProgressRingView(
                        progress: viewModel.progress,
                        percentText: viewModel.progressPercentText,
                        elapsedText: viewModel.elapsedText,
                        etaText: viewModel.etaText
                    )

                    VStack(spacing: 8) {
                        Text(viewModel.stepText)
                        Text(viewModel.chunkText)
                    }
                    .font(.title3.weight(.regular))
                    .foregroundStyle(.white.opacity(0.62))
                    .monospacedDigit()
                    .padding(.top, 42)

                    Spacer(minLength: 28)

                    VStack(spacing: 22) {
                        TemperatureIndicatorView(thermalState: viewModel.thermalState)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isShowingDetails.toggle()
                            }
                        } label: {
                            Label(isShowingDetails ? "Hide Details" : "More Info", systemImage: isShowingDetails ? "chevron.down" : "chevron.up")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.74))

                        if isShowingDetails {
                            TrainingDetailsView(viewModel: viewModel)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 26)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct TrainingFullScreenHeader: View {
    let onDim: () -> Void
    let onExit: () -> Void

    var body: some View {
        HStack {
            Button("Exit Training", action: onExit)
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.86))

            Spacer()

            Button(action: onDim) {
                Label("Dim Screen", systemImage: "sun.max")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .foregroundStyle(.white.opacity(0.82))
            .accessibilityLabel("Dim Screen")
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }
}

private struct DimmedTrainingView: View {
    @ObservedObject var viewModel: TrainingSettingsViewModel

    var body: some View {
        VStack(spacing: 12) {
            ProgressRingView(
                progress: viewModel.progress,
                percentText: viewModel.progressPercentText,
                elapsedText: "",
                etaText: "",
                ringSize: 128,
                lineWidth: 4,
                isDimmed: true
            )
            Text(viewModel.stepText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.16))
        }
    }
}

struct ProgressRingView: View {
    let progress: Double?
    let percentText: String
    let elapsedText: String
    let etaText: String
    var ringSize: CGFloat = 276
    var lineWidth: CGFloat = 4
    var isDimmed = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(isDimmed ? 0.10 : 0.28), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white.opacity(isDimmed ? 0.28 : 0.95), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: 0.68)
                    .stroke(Color.white.opacity(isDimmed ? 0.20 : 0.70), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: isDimmed ? 0 : 14) {
                Text(percentText)
                    .font(.system(size: isDimmed ? 30 : 80, weight: .light, design: .default))
                    .foregroundStyle(.white.opacity(isDimmed ? 0.24 : 0.96))
                    .monospacedDigit()

                if !isDimmed {
                    VStack(spacing: 8) {
                        Text("\(elapsedText) elapsed")
                        Text("ETA \(etaText)")
                    }
                    .font(.title3.weight(.regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                }
            }
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityLabel("Training progress")
        .accessibilityValue(percentText)
    }
}

struct TemperatureIndicatorView: View {
    let thermalState: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.52, green: 0.68, blue: 0.88),
                                Color(red: 0.80, green: 0.78, blue: 0.62),
                                Color(red: 0.94, green: 0.64, blue: 0.28)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(0.88)

                Rectangle()
                    .fill(Color.white.opacity(0.82))
                    .frame(width: 2, height: 16)
                    .offset(x: max(0, min(proxy.size.width - 2, proxy.size.width * indicatorPosition)))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Phone temperature")
    }

    private var indicatorPosition: CGFloat {
        switch thermalState {
        case "critical": return 0.96
        case "serious": return 0.76
        case "fair": return 0.45
        case "nominal": return 0.20
        default: return 0.18
        }
    }
}

struct TrainingDetailsView: View {
    @ObservedObject var viewModel: TrainingSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                TrainingMetricCell(title: "Loss", value: lossText)
                TrainingMetricCell(title: "Memory", value: memoryText)
                TrainingMetricCell(title: "App State", value: viewModel.latestStep?.appState ?? viewModel.report?.appStateEvents.last?.state ?? "--")
                TrainingMetricCell(title: "Protected Data", value: protectedDataText)
                TrainingMetricCell(title: "Main Stalls", value: "\(viewModel.report?.mainThreadStalls.count ?? 0)")
                TrainingMetricCell(title: "Run", value: viewModel.runID ?? "--")
            }

            TrainingLogsView(logs: viewModel.recentLogs)
        }
        .padding(.top, 2)
    }

    private var lossText: String {
        if let loss = viewModel.latestStep?.loss ?? viewModel.report?.stepMetrics.last?.loss {
            return loss.formatted(.number.precision(.fractionLength(4)))
        }
        return "--"
    }

    private var memoryText: String {
        let value = viewModel.latestStep?.memoryMB ?? viewModel.report?.peakMemoryMB
        guard let value else { return "--" }
        return "\(Int(value.rounded())) MB"
    }

    private var protectedDataText: String {
        guard let value = viewModel.latestStep?.protectedDataAvailable ?? viewModel.report?.appStateEvents.last?.protectedDataAvailable else {
            return "--"
        }
        return value ? "Available" : "Unavailable"
    }
}

private struct TrainingMetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

struct TrainingLogsView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Logs")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.52))

            if logs.isEmpty {
                Text("Logs will appear when training starts.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                    Text(log)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(2)
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
