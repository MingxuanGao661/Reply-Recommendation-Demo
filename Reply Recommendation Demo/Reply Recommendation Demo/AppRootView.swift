import SwiftUI

struct AppRootView: View {
    @StateObject private var settingsStore: AppSettingsStore
    @StateObject private var threadListViewModel: ThreadListViewModel
    private let chatService: DemoChatServiceProtocol

    init() {
        let settingsStore = AppSettingsStore()
        let chatService = DemoChatService.shared
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _threadListViewModel = StateObject(
            wrappedValue: ThreadListViewModel(service: chatService)
        )
        self.chatService = chatService
    }

    var body: some View {
        ChatWorkspaceView(
            threadListViewModel: threadListViewModel,
            chatService: chatService
        )
            .environmentObject(settingsStore)
            .dynamicTypeSize(.xSmall ... .large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
            }
            .task {
                warmUpLocalEngineIfNeeded()
            }
    }

    private func warmUpLocalEngineIfNeeded() {
        guard settingsStore.backendMode == .local,
              !settingsStore.isRunningInXcodePreview else { return }
        let lor = settingsStore.resolvedLocalLoraConfiguration()
        LocalReplyEngine(
            modelResourceName: settingsStore.bundledLlamaModel.resourceName,
            loraResourceName: lor.bundledResourceName,
            loraAdapterFilePath: lor.userAdapterPath
        )
        .warmUp()
    }
}

#Preview {
    AppRootView()
}
