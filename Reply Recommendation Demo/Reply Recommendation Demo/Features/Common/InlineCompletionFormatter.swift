import Foundation

enum InlineCompletionFormatter {
    static func fullText(draftPrefix: String, rawOutput: String) -> String {
        let continuation = cleanedMessage(rawOutput)
        guard !draftPrefix.isEmpty else { return continuation }
        if continuation.lowercased().hasPrefix(draftPrefix.lowercased()) {
            return continuation
        }
        return appendContinuation(draftPrefix: draftPrefix, continuation: continuation)
    }

    static func cleanedMessage(_ rawText: String) -> String {
        let hardStops = [
            "\n",
            "{",
            "}",
            "<|eot_id|>",
            "<|start_header_id|>",
            "<|end_header_id|>",
            "```",
        ]

        var text = rawText
        for stop in hardStops {
            if let range = text.range(of: stop) {
                text = String(text[..<range.lowerBound])
            }
        }

        text = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["Me:", "me:", "ME:", "Assistant:", "assistant:", "Other:", "other:"] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return text
    }

    static func visibleSuffix(fullText: String, draftPrefix: String) -> String? {
        guard fullText.lowercased().hasPrefix(draftPrefix.lowercased()) else {
            return nil
        }
        let suffix = String(fullText.dropFirst(draftPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private static func appendContinuation(draftPrefix: String, continuation: String) -> String {
        let draft = draftPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var suffix = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return draft }

        if let deduped = deduplicatedContinuation(draft: draft, continuation: suffix) {
            suffix = deduped
        }

        let noSpaceBefore = CharacterSet(charactersIn: ".,!?;:%)]}")
        if let firstScalar = suffix.unicodeScalars.first,
           noSpaceBefore.contains(firstScalar) {
            return draft + suffix
        }
        return draft + " " + suffix
    }

    private static func deduplicatedContinuation(draft: String, continuation: String) -> String? {
        let draftWords = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        let continuationWords = continuation.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !draftWords.isEmpty, !continuationWords.isEmpty else { return nil }

        let maxOverlap = min(draftWords.count, continuationWords.count)
        for overlapCount in stride(from: maxOverlap, through: 1, by: -1) {
            let draftSuffix = Array(draftWords.suffix(overlapCount)).map { $0.lowercased() }
            guard overlapCount >= 2 || (draftSuffix.first?.count ?? 0) >= 4 else {
                continue
            }

            for start in 0...(continuationWords.count - overlapCount) {
                let candidate = continuationWords[start..<(start + overlapCount)].map { $0.lowercased() }
                if candidate == draftSuffix {
                    let remaining = continuationWords.dropFirst(start + overlapCount).joined(separator: " ")
                    return remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }
}
