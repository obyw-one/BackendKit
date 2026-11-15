import Foundation

// MARK: - DuckDBDecimalParts

//
// A `Decimal` taken apart into what DuckDB's DECIMAL(38, scale) takes: a sign, the unscaled integer's decimal digits
// and a scale. Both drivers bind a decimal from THIS, so both accept and refuse exactly the same values:
//   - more than 38 significant digits, or a scale above 38, is refused (`unsupportedBind`), never rounded or truncated;
//   - NaN is refused;
//   - zero is bound as the integer 0. duckdb-swift builds a zero decimal with width 0, and DuckDB aborts the whole
//     process on that (an uncaught C++ assertion in `DecimalType::GetWidth`), so zero never reaches a decimal bind.
// The digits are read from `Decimal`'s own `description` (plain digits, `.` separator, no exponent form), because
// Linux's Foundation does not expose the mantissa and exponent members the Apple build reads.

struct DuckDBDecimalParts: Equatable {
    static let maxDigits = 38

    let isNegative: Bool
    /// The unscaled magnitude's digits, no leading zeros (`"0"` for zero).
    let digits: String
    let scale: Int

    var isZero: Bool { digits == "0" }

    init(_ value: Decimal) throws {
        guard value.isFinite else { throw DuckDBSQLError.unsupportedBind("decimal \(value)") }
        let text = value.description
        let negative = text.hasPrefix("-")
        let unsigned = negative ? String(text.dropFirst()) : text
        let halves = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(halves.count), halves.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            throw DuckDBSQLError.unsupportedBind("decimal \(text)")
        }
        let fraction = halves.count == 2 ? halves[1] : ""
        let trimmed = (halves[0] + fraction).drop(while: { $0 == "0" })
        guard trimmed.count <= Self.maxDigits, fraction.count <= Self.maxDigits else {
            throw DuckDBSQLError.unsupportedBind("decimal \(text): DuckDB DECIMAL holds at most \(Self.maxDigits) digits and scale \(Self.maxDigits)")
        }
        isNegative = negative && !trimmed.isEmpty
        digits = trimmed.isEmpty ? "0" : String(trimmed)
        scale = fraction.count
    }
}
