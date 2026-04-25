import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                        Text("Xcode Previews skips Local GGUF inference to avoid preview-host crashes. Use Simulator or a device for Local mode.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if settingsStore.availableBackendModes.contains(.local) {
                    Section("On-device Llama") {
                        Picker("Bundled GGUF", selection: $settingsStore.bundledLlamaModel) {
                            ForEach(BundledLlamaModelOption.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        Text("Applies when Backend is Local. Switching model unloads the previous one on next generation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Cloud") {
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

                Section("Conversation Override") {
                    Picker(
                        "Demo scenario",
                        selection: Binding(
                            get: { viewModel.scenario },
                            set: { viewModel.applyScenario($0) }
                        )
                    ) {
                        ForEach(DemoScenario.allCases) { scenario in
                            Text(scenario.displayName).tag(scenario)
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

                Section("Privacy") {
                    Label("No screen scraping or keyboard extension permissions are required for this V1 demo.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Label("Local mode runs against the bundled GGUF model when available.", systemImage: "iphone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .task {
                viewModel.refreshEngineStatus()
            }
        }
        .presentationDetents([.large])
    }
}

#Preview {
    let settingsStore = AppSettingsStore()
    return SettingsScreen(
        viewModel: ChatViewModel(settingsStore: settingsStore)
    )
    .environmentObject(settingsStore)
}
