import SwiftUI

struct AppRootView: View {
    @StateObject private var settingsStore: AppSettingsStore
    @StateObject private var chatViewModel: ChatViewModel

    init() {
        let settingsStore = AppSettingsStore()
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _chatViewModel = StateObject(
            wrappedValue: ChatViewModel(settingsStore: settingsStore)
        )
    }

    var body: some View {
        ChatScreen(viewModel: chatViewModel)
            .environmentObject(settingsStore)
            .dynamicTypeSize(.xSmall ... .large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
            }
    }
}

#Preview {
    AppRootView()
}
