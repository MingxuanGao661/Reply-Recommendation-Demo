import SwiftUI

struct ChatWorkspaceView: View {
    @StateObject private var threadListViewModel: ThreadListViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @State private var isShowingNewChat = false
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
                isCreatingThread: threadListViewModel.isCreatingThread,
                errorMessage: threadListViewModel.errorMessage,
                onRefresh: {
                    Task { await threadListViewModel.loadThreads() }
                },
                onNewChat: {
                    isShowingNewChat = true
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
        .sheet(isPresented: $isShowingNewChat) {
            NewChatSheet(isCreating: threadListViewModel.isCreatingThread) { draft in
                await threadListViewModel.createThread(draft)
            }
        }
    }
}

private struct ThreadSidebar: View {
    let threads: [DemoThreadListItem]
    @Binding var selectedThreadID: UUID?
    let isLoading: Bool
    let isCreatingThread: Bool
    let errorMessage: String?
    let onRefresh: () -> Void
    let onNewChat: () -> Void

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
                    ThreadRow(
                        thread: thread,
                        isSelected: selectedThreadID == thread.id
                    )
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
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(isCreatingThread)
                .accessibilityLabel("New Chat")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Chats")
            }
        }
    }
}

private struct NewChatSheet: View {
    let isCreating: Bool
    let onCreate: (DemoNewThreadDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var subtitle = ""
    @State private var currentUserName = "Me"
    @State private var otherParticipants = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Chat") {
                    TextField("Thread name", text: $title)
                    TextField("Subtitle", text: $subtitle)
                }

                Section("Participants") {
                    TextField("Current user", text: $currentUserName)
                    TextField("Other participants, comma separated", text: $otherParticipants, axis: .vertical)
                        .lineLimit(2 ... 4)

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        create()
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private func create() {
        guard let draft = makeDraft() else { return }
        Task {
            let didCreate = await onCreate(draft)
            if didCreate {
                dismiss()
            }
        }
    }

    private func makeDraft() -> DemoNewThreadDraft? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCurrentUser = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = otherParticipants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanTitle.isEmpty else {
            validationMessage = "Add a thread name."
            return nil
        }
        guard !cleanCurrentUser.isEmpty else {
            validationMessage = "Add the current user's name."
            return nil
        }
        guard !others.isEmpty else {
            validationMessage = "Add at least one other participant."
            return nil
        }

        var usedIDs: Set<String> = ["me"]
        let otherParticipantRecords = others.map { name in
            let participantID = uniqueParticipantID(for: name, usedIDs: &usedIDs)
            return DemoNewThreadParticipant(
                participantID: participantID,
                displayName: name,
                relationship: "participant",
                isSelf: false
            )
        }

        validationMessage = nil
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return DemoNewThreadDraft(
            title: cleanTitle,
            subtitle: trimmedSubtitle.isEmpty ? "Live demo chat" : trimmedSubtitle,
            defaultComposerParticipantID: "me",
            replyToParticipantID: otherParticipantRecords.first?.participantID,
            participants: [
                DemoNewThreadParticipant(
                    participantID: "me",
                    displayName: cleanCurrentUser,
                    relationship: "self",
                    isSelf: true
                ),
            ] + otherParticipantRecords
        )
    }

    private func uniqueParticipantID(for name: String, usedIDs: inout Set<String>) -> String {
        let normalized = name
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        var base = String(normalized)
            .split(separator: "_")
            .joined(separator: "_")
        if base.isEmpty || base == "me" {
            base = "participant"
        }

        var candidate = base
        var suffix = 2
        while usedIDs.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        usedIDs.insert(candidate)
        return candidate
    }
}

private struct ThreadRow: View {
    let thread: DemoThreadListItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            DemoThreadAvatar(
                title: thread.title,
                unreadCount: thread.unreadCount,
                profileColors: profileColors
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(thread.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let lastAt = thread.lastMessage?.createdAt {
                        Text(lastAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                }

                Text(thread.subtitle)
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)

                Text(thread.lastMessage?.content ?? "No messages yet")
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var profileColors: DemoParticipantColorProfile {
        DemoChatPalette.profileColors(
            speakerId: representativeParticipantID,
            selfId: thread.thread.defaultComposerParticipantID,
            orderedParticipantIds: orderedParticipantIDs
        )
    }

    private var representativeParticipantID: String {
        if let replyTo = thread.thread.replyToParticipantID {
            return replyTo
        }
        return thread.participants
            .sorted { $0.sortOrder < $1.sortOrder }
            .first { !$0.isSelf }?
            .participantID ?? thread.thread.defaultComposerParticipantID
    }

    private var orderedParticipantIDs: [String] {
        thread.participants
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.participantID)
    }

    private var primaryTextColor: Color {
        isSelected ? .white : .primary
    }

    private var secondaryTextColor: Color {
        isSelected ? Color.white.opacity(0.78) : Color.secondary
    }
}

private struct DemoThreadAvatar: View {
    let title: String
    let unreadCount: Int
    let profileColors: DemoParticipantColorProfile

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(profileColors.avatarFill)
                .frame(width: 42, height: 42)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .overlay {
                    Text(initials)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(profileColors.avatarForeground)
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
