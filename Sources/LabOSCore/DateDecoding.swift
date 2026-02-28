import Foundation

extension JSONDecoder.DateDecodingStrategy {
    /// Decodes ISO 8601 dates with or without fractional seconds.
    /// Handles both `2026-02-27T20:31:41Z` and `2026-02-27T20:31:41.482Z`.
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }

            let whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
            if let date = whole.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date string, got \(string)"
            )
        }
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// Encodes dates as ISO 8601 with fractional seconds for round-trip compatibility.
    static var iso8601WithFractionalSeconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(f.string(from: date))
        }
    }
}
