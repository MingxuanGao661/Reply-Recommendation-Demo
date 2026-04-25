import SwiftUI
import UIKit

struct ChatScreen: View {
    @StateObject private var viewModel: ChatViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @State private var isShowingSettings = false

    init(viewModel: ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowTimestamp(at: index) {
                                DemoTimestampBanner(date: message.createdAt)
                                    .id("ts-\(message.id.uuidString)")
                            }
                            DemoChatMessageRow(
                                message: message,
                                showsSenderName: shouldShowSenderName(at: index),
                                isTrailing: viewModel.isTrailingMessage(message)
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
                                Task { await viewModel.generateSuggestions() }
                            }
                        )

                        Divider()

                        if viewModel.shouldShowComposerParticipantPicker {
                            ComposerParticipantPicker(
                                participants: viewModel.participants,
                                activeParticipantID: viewModel.activeComposerParticipantID,
                                onSelectParticipant: { participantID in
                                    viewModel.setActiveComposerParticipant(participantID)
                                }
                            )
                        }

                        DemoMessageComposer(
                            text: $viewModel.draftText,
                            isSendEnabled: viewModel.canSendDraft,
                            isGenerating: viewModel.isGenerating,
                            onGenerate: {
                                Task { await viewModel.generateSuggestions() }
                            },
                            onSend: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    viewModel.sendDraft()
                                }
                            }
                        )
                    }
                    .background(Color(uiColor: .systemBackground))
                }
                .background {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ChatHeaderView(
                            title: viewModel.threadTitle,
                            subtitle: viewModel.threadSubtitle,
                            badgeText: viewModel.backendBadgeText
                        )
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Open Settings")
                    }
                }
                .task {
                    await viewModel.bootstrapIfNeeded()
                }
                .sheet(isPresented: $isShowingSettings) {
                    SettingsScreen(viewModel: viewModel)
                        .environmentObject(settingsStore)
                }
                .alert(
                    "Suggestion Engine",
                    isPresented: Binding(
                        get: { viewModel.errorMessage != nil },
                        set: { if !$0 { viewModel.clearError() } }
                    )
                ) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
            }
        }
    }

    private let bottomAnchorId = "reply-demo-bottom"

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
        viewModel: ChatViewModel(settingsStore: settingsStore)
    )
    .environmentObject(settingsStore)
}
