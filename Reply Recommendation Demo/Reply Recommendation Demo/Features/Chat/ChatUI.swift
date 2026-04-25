import SwiftUI
import UIKit

struct DemoMessageBubble: View {
    let text: String
    let isSelf: Bool

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(isSelf ? .white : .primary)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        isSelf
                            ? Color.accentColor
                            : Color(uiColor: .secondarySystemBackground)
                    )
            )
            .contextMenu {
                Button("Copy") {
                    UIPasteboard.general.string = text
                }
            }
    }
}

struct DemoChatMessageRow: View {
    let message: ChatMessageItem
    let showsSenderName: Bool

    var body: some View {
        VStack(
            alignment: message.isSelf ? .trailing : .leading,
            spacing: 4
        ) {
            if showsSenderName, !message.isSelf {
                Text(message.speakerName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if message.isSelf {
                    Spacer(minLength: 44)
                    DemoMessageBubble(text: message.text, isSelf: true)
                } else {
                    DemoAvatarBadge(name: message.speakerName)
                    DemoMessageBubble(text: message.text, isSelf: false)
                    Spacer(minLength: 44)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct DemoMessageComposer: View {
    @Binding var text: String
    let isSendEnabled: Bool
    let onGenerate: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )

            Button(action: onGenerate) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
            .accessibilityLabel("Generate Suggestions")

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSendEnabled ? .white : .secondary)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(
                                isSendEnabled
                                    ? Color.accentColor
                                    : Color(uiColor: .tertiarySystemFill)
                            )
                    )
            }
            .disabled(!isSendEnabled)
            .accessibilityLabel("Send Message")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

struct SuggestionShelf: View {
    let suggestions: [ReplySuggestionItem]
    let isLoading: Bool
    let metricsSummary: String?
    let onPickSuggestion: (ReplySuggestionItem) -> Void
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Smart Replies", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if let metricsSummary {
                    Text(metricsSummary)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                }

                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Regenerate Suggestions")
            }

            if isLoading {
                HStack(spacing: 10) {
                    SuggestionSkeletonCard()
                    SuggestionSkeletonCard()
                    SuggestionSkeletonCard()
                }
            } else if suggestions.isEmpty {
                Text("Tap the sparkle button or Regenerate to draft contextual replies.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                onPickSuggestion(suggestion)
                            } label: {
                                SuggestionCard(suggestion: suggestion)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(
            Rectangle()
                .fill(Color(uiColor: .systemBackground))
        )
    }
}

private struct SuggestionCard: View {
    let suggestion: ReplySuggestionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .textCase(.uppercase)

            Text(suggestion.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(width: 184, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

private struct SuggestionSkeletonCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 104, height: 96)
            .overlay {
                ProgressView()
            }
    }
}

struct DemoTimestampBanner: View {
    let date: Date

    var body: some View {
        Text(labelText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .frame(maxWidth: .infinity)
    }

    private var labelText: String {
        let calendar = Calendar.current
        let timeText = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today \(timeText)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(timeText)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct DemoAvatarBadge: View {
    let name: String

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.2))
            .frame(width: 30, height: 30)
            .overlay {
                Text(initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
    }

    private var initials: String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        let text = String(parts).uppercased()
        return text.isEmpty ? "?" : text
    }
}
