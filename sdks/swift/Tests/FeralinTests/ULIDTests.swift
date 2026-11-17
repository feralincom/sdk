import XCTest
@testable import Feralin

final class ULIDTests: XCTestCase {
    private let fixedMillis: Int64 = 1_793_703_600_000

    func testFormat() {
        var generator = ULIDGenerator()
        for offset in 0..<1000 {
            XCTAssertTrue(isULID(generator.next(millis: fixedMillis + Int64(offset))))
        }
        for bad in ["", "01ARZ3NDEKTSV4RRFFQ69G5FAV1", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAI", "81ARZ3NDEKTSV4RRFFQ69G5FAV"] {
            XCTAssertFalse(isULID(bad), bad)
        }
    }

    func testTimestampPrefix() {
        var generator = ULIDGenerator()
        let value = generator.next(millis: fixedMillis)
        var millis: Int64 = 0
        for character in value.prefix(10) {
            millis = millis * 32 + Int64(ULIDGenerator.alphabet.firstIndex(of: character) ?? 0)
        }
        XCTAssertEqual(millis, fixedMillis)
    }

    func testMonotonicWithinSameMillisecond() {
        var generator = ULIDGenerator()
        var previous = generator.next(millis: fixedMillis)
        for _ in 0..<5000 {
            let current = generator.next(millis: fixedMillis)
            XCTAssertLessThan(previous, current)
            XCTAssertEqual(previous.prefix(10), current.prefix(10))
            previous = current
        }
    }

    func testMonotonicWhenClockGoesBackwards() {
        var generator = ULIDGenerator()
        let first = generator.next(millis: fixedMillis)
        XCTAssertGreaterThan(generator.next(millis: fixedMillis - 10_000), first)
    }

    func testRandomOverflowAdvancesTime() {
        var generator = ULIDGenerator()
        let first = generator.next(millis: fixedMillis)
        generator.saturateRandomForTesting()
        let next = generator.next(millis: fixedMillis)
        XCTAssertGreaterThan(next, first)
        XCTAssertNotEqual(next.prefix(10), first.prefix(10))
    }
}
