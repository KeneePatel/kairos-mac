/// Phone numbers in E.164 form ("+14165550123"), with +1 assumed when no country code is given.
public enum PhoneNumber {
    private static let allowed = Set("0123456789 -.()")

    /// The E.164 form of `text`, or nil if it can't be a full phone number. Extensions aren't kept,
    /// so a number with one is rejected rather than silently shortened.
    public static func e164(_ text: String) -> String? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var international = false
        if rest.first == "+" {
            international = true
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty, rest.allSatisfy(allowed.contains) else { return nil }
        var digits = rest.filter(\.isNumber)
        if !international && digits.hasPrefix("00") {
            // "00" is the international call prefix in most of the world.
            digits.removeFirst(2)
            international = true
        }
        if !international {
            if digits.count == 10 {
                digits = "1" + digits
            } else if !(digits.count == 11 && digits.first == "1") {
                return nil
            }
        }
        guard (8...15).contains(digits.count) else { return nil }
        if digits.first == "1" {
            // North America: 1, then an area code and an exchange that each start with 2–9.
            let numbers = Array(digits)
            guard numbers.count == 11, ("2"..."9").contains(numbers[1]), ("2"..."9").contains(numbers[4]) else {
                return nil
            }
        }
        return "+" + digits
    }
}
