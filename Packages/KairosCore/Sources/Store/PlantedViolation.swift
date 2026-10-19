func plantedViolation() -> Int {
    try! Int(String(42), radix: 10) ?? 0
}
