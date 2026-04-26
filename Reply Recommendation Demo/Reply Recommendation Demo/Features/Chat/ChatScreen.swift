import SwiftUI
import UIKit

struct ChatScreen: View {
    @StateObject private var viewModel: ChatViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSettings = false
    @State private var suggestionTask: Task<Void, Never>?

    init(viewModel: ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowTimestamp(at: index) {
                                DemoTimestampBanner(date: message.createdAt)
                                    .id("ts-\(message.id.uuidString)")
                            }
                            DemoChatMessageRow(
                                message: message,
                                showsSenderName: shouldShowSenderName(at: index),
                                isTrailing: viewModel.isTrailingMessage(message),
                                profileColors: DemoChatPalette.profileColors(
                                    speakerId: message.speakerId,
                                    selfId: viewModel.activeComposerParticipantID,
                                    orderedParticipantIds: viewModel.participants.map(\.id)
                                ),
                                isSelected: viewModel.selectedReplyMessageID == message.id,
                                onTap: { viewModel.selectReplyTarget(messageID: message.id) },
                                canDelete: viewModel.canDeleteMessage(message),
                                onDelete: {
                                    Task<Void, Never> {
                                        await viewModel.deleteMessage(message)
                                    }
                                }
                            )
                            .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorId)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                )
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: viewModel.suggestionSlots.count) { _, _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: viewModel.draftText) { _, _ in
                    viewModel.scheduleInlineSuggestionGeneration()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()

                        SuggestionShelf(
                            suggestionSlots: viewModel.suggestionSlots,
                            isLoading: viewModel.isGenerating,
                            metricsSummary: viewModel.metricsSummary,
                            onPickSuggestion: { suggestion in
                                viewModel.insertSuggestion(suggestion)
                            },
                            onRegenerate: {
                                startSuggestionGeneration()
                            }
                        )

                        Divider()

                        if let replyMsg = viewModel.selectedReplyMessage {
                            ReplyTargetBanner(
                                speakerName: replyMsg.speakerName,
                                previewText: replyMsg.text,
                                onDismiss: { viewModel.clearReplyTarget() }
                            )
                        }

                        DemoMessageComposer(
                            text: $viewModel.draftText,
                            isSendEnabled: viewModel.canSendDraft,
                            isGenerating: viewModel.isGenerating,
                            ghostSuffix: viewModel.inlineGhostSuffix,
                            onGenerate: {
                                startSuggestionGeneration()
                            },
                            onAcceptInline: {
                                viewModel.acceptInlineSuggestion()
                            },
                            onSend: {
                                Task<Void, Never> { await viewModel.sendDraft() }
                            }
                        )
                    }
                    .background(Color(uiColor: .systemBackground))
                }
                .background {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                }
                .navigationTitle(viewModel.threadTitle)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(trailing: settingsButton)
                .task {
                    await viewModel.bootstrapIfNeeded()
                }
                .onDisappear {
                    suggestionTask?.cancel()
                    suggestionTask = nil
                    viewModel.teardown()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task<Void, Never> {
                            await viewModel.resumeAfterBackgrounding()
                        }
                    case .inactive, .background:
                        suggestionTask?.cancel()
                        suggestionTask = nil
                        viewModel.suspendForBackgrounding()
                    @unknown default:
                        break
                    }
                }
                .sheet(isPresented: $isShowingSettings) {
                    SettingsScreen(viewModel: viewModel)
                        .environmentObject(settingsStore)
                }
            }
        }
    }

    private let bottomAnchorId = "reply-demo-bottom"

    private func startSuggestionGeneration() {
        suggestionTask?.cancel()
        suggestionTask = Task<Void, Never> {
            await viewModel.generateSuggestions()
        }
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Open Settings")
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }

    private func shouldShowSenderName(at index: Int) -> Bool {
        guard index < viewModel.messages.count else { return false }
        let message = viewModel.messages[index]
        guard !viewModel.isTrailingMessage(message) else { return false }
        guard index > 0 else { return true }
        let previous = viewModel.messages[index - 1]
        if previous.speakerId != message.speakerId { return true }
        return message.createdAt.timeIntervalSince(previous.createdAt) > 300
    }

    private func shouldShowTimestamp(at index: Int) -> Bool {
        guard index < viewModel.messages.count else { return false }
        guard index > 0 else { return true }
        let currentDate = viewModel.messages[index].createdAt
        let previousDate = viewModel.messages[index - 1].createdAt
        if !Calendar.current.isDate(currentDate, inSameDayAs: previousDate) {
            return true
        }
        return currentDate.timeIntervalSince(previousDate) >= 10 * 60
    }
}

private struct ChatHeaderView: View {
    let title: String
    let subtitle: String
    let badgeText: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(badgeText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.12))
                    )
            }
        }
    }
}

#Preview {
    let settingsStore = AppSettingsStore()
    return ChatScreen(
        viewModel: ChatViewModel(
            settingsStore: settingsStore,
            chatService: DemoChatService.shared
        )
    )
    .environmentObject(settingsStore)
}
