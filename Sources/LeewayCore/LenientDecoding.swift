import Foundation

// The usage endpoints are undocumented and can change. These helpers read a field when it has a usable
// value and give nil otherwise, so one odd field never fails the whole reading.

/// A number that a server sends as a JSON number or as text.
struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self), let number = Double(text) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number")
        }
    }
}

/// A date as Unix seconds, Unix milliseconds or ISO 8601 text.
struct FlexibleDate: Decodable {
    let value: Date

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        } else if let text = try? container.decode(String.self), let date = Self.parse(text) {
            value = date
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date")
        }
    }

    static func parse(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func number(_ key: Key) -> Double? { lenient(FlexibleDouble.self, key)?.value }
    func date(_ key: Key) -> Date? { lenient(FlexibleDate.self, key)?.value }
    func string(_ key: Key) -> String? { lenient(String.self, key) }

    func nested<NestedKey: CodingKey>(_ type: NestedKey.Type, _ key: Key) -> KeyedDecodingContainer<NestedKey>? {
        try? nestedContainer(keyedBy: type, forKey: key)
    }
}
