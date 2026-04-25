import Foundation

enum SupabaseJSONCoders {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseISO8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .supabaseISO8601
        return encoder
    }
}

private enum SupabaseISO8601Formatters {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.utc
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.utc
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        if let date = fractional.date(from: value) { return date }
        if let date = plain.date(from: value) { return date }
        if let truncated = truncateFractionalSeconds(value), let date = fractional.date(from: truncated) {
            return date
        }
        return nil
    }

    private static func truncateFractionalSeconds(_ value: String, maxDigits: Int = 3) -> String? {
        guard let dot = value.firstIndex(of: ".") else { return nil }
        let start = value.index(after: dot)
        var end = start
        while end < value.endIndex, value[end].isNumber {
            end = value.index(after: end)
        }

        let digits = value[start..<end]
        guard digits.count > maxDigits else { return nil }
        return String(value[..<start] + digits.prefix(maxDigits) + value[end...])
    }
}

private extension TimeZone {
    static let utc = TimeZone(secondsFromGMT: 0) ?? .current
}

extension JSONDecoder.DateDecodingStrategy {
    static let supabaseISO8601: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let date = SupabaseISO8601Formatters.parse(value) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO8601 date: \(value)"
        )
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static let supabaseISO8601: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(SupabaseISO8601Formatters.fractional.string(from: date))
    }
}
