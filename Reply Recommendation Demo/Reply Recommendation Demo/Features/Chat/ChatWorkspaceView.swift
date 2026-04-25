import SwiftUI

struct ChatWorkspaceView: View {
    @StateObject private var threadListViewModel: ThreadListViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    private let chatService: DemoChatServiceProtocol

    init(
        threadListViewModel: ThreadListViewModel,
        chatService: DemoChatServiceProtocol
    ) {
        _threadListViewModel = StateObject(wrappedValue: threadListViewModel)
        self.chatService = chatService
    }

    var body: some View {
        NavigationSplitView {
            ThreadSidebar(
                threads: threadListViewModel.threads,
                selectedThreadID: Binding(
                    get: { threadListViewModel.selectedThreadID },
                    set: { threadListViewModel.selectThread($0) }
                ),
                isLoading: threadListViewModel.isLoading,
                errorMessage: threadListViewModel.errorMessage,
                onRefresh: {
                    Task { await threadListViewModel.loadThreads() }
                }
            )
            .navigationTitle("Chats")
        } detail: {
            if let item = threadListViewModel.selectedThreadItem {
                ChatScreen(
                    viewModel: ChatViewModel(
                        threadItem: item,
                        settingsStore: settingsStore,
                        chatService: chatService,
                        onMessageReceived: { message in
                            threadListViewModel.ingest(message)
                        }
                    )
                )
                .id(item.id)
                .environmentObject(settingsStore)
            } else {
                ContentUnavailableView(
                    "No Chats",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Threads will appear here after they load.")
                )
            }
        }
        .task {
            await threadListViewModel.loadThreads()
        }
    }
}

private struct ThreadSidebar: View {
    let threads: [DemoThreadListItem]
    @Binding var selectedThreadID: UUID?
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () -> Void

    var body: some View {
        List(selection: $selectedThreadID) {
            if let errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Supabase offline", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                ForEach(threads) { thread in
                    ThreadRow(thread: thread)
                        .tag(thread.id)
                }
            }
        }
        .overlay {
            if isLoading && threads.isEmpty {
                ProgressView()
            }
        }
        .refreshable {
            onRefresh()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Chats")
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: DemoThreadListItem

    var body: some View {
        HStack(spacing: 12) {
            DemoThreadAvatar(title: thread.title, unreadCount: thread.unreadCount)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(thread.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let lastAt = thread.lastMessage?.createdAt {
                        Text(lastAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(thread.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(thread.lastMessage?.content ?? "No messages yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct DemoThreadAvatar: View {
    let title: String
    let unreadCount: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 42, height: 42)
                .overlay {
                    Text(initials)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }

            if unreadCount > 0 {
                Text(unreadText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, unreadCount > 9 ? 4 : 0)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 4, y: -4)
            }
        }
        .frame(width: 46, height: 46)
    }

    private var initials: String {
        let parts = title
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        let text = String(parts).uppercased()
        return text.isEmpty ? "?" : text
    }

    private var unreadText: String {
        unreadCount > 9 ? "9+" : "\(unreadCount)"
    }
}

#Preview {
    let settingsStore = AppSettingsStore()
    return ChatWorkspaceView(
        threadListViewModel: ThreadListViewModel(service: DemoChatService.shared),
        chatService: DemoChatService.shared
    )
    .environmentObject(settingsStore)
}
