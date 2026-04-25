import SwiftUI
import UIKit

// MARK: - Muted participant palette

enum DemoChatPalette {
    private static let selfProfile = DemoParticipantColorProfile(
        bubbleFill: adaptiveColor(
            light: (0.902, 0.949, 0.980),
            dark: (0.160, 0.282, 0.365)
        ),
        avatarFill: adaptiveColor(
            light: (0.765, 0.875, 0.941),
            dark: (0.204, 0.361, 0.475)
        ),
        avatarForeground: adaptiveColor(
            light: (0.204, 0.361, 0.475),
            dark: (0.752, 0.878, 0.949)
        )
    )

    private static let participantProfiles: [DemoParticipantColorProfile] = [
        DemoParticipantColorProfile(
            bubbleFill: adaptiveColor(
                light: (0.965, 0.918, 0.933),
                dark: (0.361, 0.218, 0.263)
            ),
            avatarFill: adaptiveColor(
                light: (0.902, 0.765, 0.804),
                dark: (0.494, 0.251, 0.318)
            ),
            avatarForeground: adaptiveColor(
                light: (0.494, 0.251, 0.318),
                dark: (0.965, 0.816, 0.859)
            )
        ),
        DemoParticipantColorProfile(
            bubbleFill: adaptiveColor(
                light: (0.922, 0.953, 0.902),
                dark: (0.220, 0.333, 0.192)
            ),
            avatarFill: adaptiveColor(
                light: (0.788, 0.875, 0.729),
                dark: (0.275, 0.420, 0.235)
            ),
            avatarForeground: adaptiveColor(
                light: (0.275, 0.420, 0.235),
                dark: (0.820, 0.933, 0.776)
            )
        ),
        DemoParticipantColorProfile(
            bubbleFill: adaptiveColor(
                light: (0.973, 0.949, 0.875),
                dark: (0.384, 0.314, 0.165)
            ),
            avatarFill: adaptiveColor(
                light: (0.910, 0.827, 0.639),
                dark: (0.506, 0.392, 0.173)
            ),
            avatarForeground: adaptiveColor(
                light: (0.506, 0.392, 0.173),
                dark: (0.949, 0.871, 0.667)
            )
        ),
        DemoParticipantColorProfile(
            bubbleFill: adaptiveColor(
                light: (0.941, 0.925, 0.973),
                dark: (0.286, 0.247, 0.392)
            ),
            avatarFill: adaptiveColor(
                light: (0.820, 0.780, 0.910),
                dark: (0.361, 0.302, 0.510)
            ),
            avatarForeground: adaptiveColor(
                light: (0.361, 0.302, 0.510),
                dark: (0.855, 0.816, 0.980)
            )
        ),
        DemoParticipantColorProfile(
            bubbleFill: adaptiveColor(
                light: (0.969, 0.929, 0.902),
                dark: (0.365, 0.263, 0.204)
            ),
            avatarFill: adaptiveColor(
                light: (0.890, 0.780, 0.694),
                dark: (0.494, 0.314, 0.235)
            ),
            avatarForeground: adaptiveColor(
                light: (0.494, 0.314, 0.235),
                dark: (0.949, 0.827, 0.745)
            )
        ),
        DemoParticipantColorProfile(
            bubbleFill: adaptiveColor(
                light: (0.902, 0.957, 0.965),
                dark: (0.176, 0.333, 0.361)
            ),
            avatarFill: adaptiveColor(
                light: (0.737, 0.859, 0.878),
                dark: (0.196, 0.408, 0.443)
            ),
            avatarForeground: adaptiveColor(
                light: (0.196, 0.408, 0.443),
                dark: (0.784, 0.925, 0.941)
            )
        ),
    ]

    /// Stable muted profile per speaker: Me = blue; others cycle by roster order.
    static func profileColors(
        speakerId: String,
        selfId: String,
        orderedParticipantIds: [String]
    ) -> DemoParticipantColorProfile {
        if speakerId == selfId { return selfProfile }
        let others = orderedParticipantIds.filter { $0 != selfId }
        guard let idx = others.firstIndex(of: speakerId) else {
            return participantProfiles[0]
        }
        return participantProfiles[idx % participantProfiles.count]
    }

    static func bubbleFill(speakerId: String, selfId: String, orderedParticipantIds: [String]) -> Color {
        profileColors(
            speakerId: speakerId,
            selfId: selfId,
            orderedParticipantIds: orderedParticipantIds
        ).bubbleFill
    }

    private static func adaptiveColor(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                let components = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: components.0,
                    green: components.1,
                    blue: components.2,
                    alpha: 1
                )
            }
        )
    }
}

struct DemoParticipantColorProfile {
    let bubbleFill: Color
    let avatarFill: Color
    let avatarForeground: Color
}

struct DemoMessageBubble: View {
    let text: String
    let fill: Color

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
    let isTrailing: Bool
    let profileColors: DemoParticipantColorProfile
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(
            alignment: isTrailing ? .trailing : .leading,
            spacing: 4
        ) {
            if showsSenderName, !isTrailing {
                Text(message.speakerName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if isTrailing {
                    Spacer(minLength: 44)
                    DemoMessageBubble(text: message.text, fill: bubbleFill)
                } else {
                    DemoAvatarBadge(
                        name: message.speakerName,
                        fill: profileColors.avatarFill,
                        foreground: profileColors.avatarForeground
                    )
                    bubbleWithHighlight
                    Spacer(minLength: 44)
                }
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isTrailing, let onTap else { return }
            withAnimation(.easeInOut(duration: 0.15)) { onTap() }
        }
    }

    @ViewBuilder
    private var bubbleWithHighlight: some View {
        DemoMessageBubble(text: message.text, fill: bubbleFill)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }

    private var bubbleFill: Color {
        profileColors.bubbleFill
    }
}

/// Banner shown above the composer when a specific message is pinned as the reply target.
struct ReplyTargetBanner: View {
    let speakerName: String
    let previewText: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(speakerName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(previewText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear reply target")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct DemoMessageComposer: View {
    @Binding var text: String
    let isSendEnabled: Bool
    let isGenerating: Bool
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
                ZStack {
                    if isGenerating {
                        ProgressView()
                            .tint(Color.accentColor)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                )
            }
            .disabled(isGenerating)
            .accessibilityLabel(isGenerating ? "Generating Suggestions" : "Generate Suggestions")

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
    let suggestionSlots: [SuggestionSlotItem]
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
                .disabled(isLoading)
                .opacity(isLoading ? 0.45 : 1)
                .accessibilityLabel("Regenerate Suggestions")
            }

            if !isLoading && suggestionSlots.isEmpty {
                Text("Tap the sparkle button or Regenerate to draft contextual replies.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(suggestionSlots) { slot in
                            if let suggestion = slot.suggestion {
                                Button {
                                    onPickSuggestion(suggestion)
                                } label: {
                                    SuggestionCard(slot: slot)
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity)
                            } else {
                                SuggestionCard(slot: slot)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(minHeight: 122)
                    .animation(.easeInOut(duration: 0.35), value: suggestionSlots)
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
    private let cardHeight: CGFloat = 110
    let slot: SuggestionSlotItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(slot.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(labelColor)
                .textCase(.uppercase)

            switch slot.state {
            case .placeholder:
                PlaceholderSuggestionBody()
            case .ready(let suggestion):
                TypewriterText(fullText: suggestion.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: 184, alignment: .topLeading)
        .frame(height: cardHeight, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay {
            if slot.isPlaceholder {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .modifier(ShimmerEffect())
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var labelColor: Color {
        slot.isPlaceholder ? .secondary : Color.accentColor
    }

    private var backgroundColor: Color {
        slot.isPlaceholder
            ? Color(uiColor: .tertiarySystemFill)
            : Color(uiColor: .secondarySystemBackground)
    }
}

private struct PlaceholderSuggestionBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 12)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 12)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 104, height: 12)
        }
        .padding(.top, 2)
    }
}

private struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -0.8

    func body(content: Content) -> some View {
        content
            .mask(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.2),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .scaleEffect(1.8)
                .offset(x: phase * 220, y: phase * 120)
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.1)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 0.8
                }
            }
    }
}

/// Reveals text word-by-word on appear, simulating a streaming / typewriter effect.
private struct TypewriterText: View {
    let fullText: String
    var wordsPerSecond: Double = 9

    @State private var visibleWordCount = 0

    private var words: [String] { fullText.components(separatedBy: " ") }

    var body: some View {
        Text(visibleWords)
            .task(id: fullText) {
                visibleWordCount = 0
                guard !words.isEmpty else { return }
                let delay = UInt64((1.0 / wordsPerSecond) * 1_000_000_000)
                for index in 1...words.count {
                    visibleWordCount = index
                    if index < words.count {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
            }
    }

    private var visibleWords: String {
        words.prefix(visibleWordCount).joined(separator: " ")
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
    let fill: Color
    let foreground: Color

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 30, height: 30)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .overlay {
                Text(initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(foreground)
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
