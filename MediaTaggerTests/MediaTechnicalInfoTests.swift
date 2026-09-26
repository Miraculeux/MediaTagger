import XCTest
@testable import MediaTagger

final class MediaTechnicalInfoTests: XCTestCase {
    func testDurationFormattingAndRounding() {
        for (seconds, expected) in [(0.1, "0:00"), (59.6, "1:00"),
                                    (592.638684807256, "9:53"), (3600.0, "1:00:00"),
                                    (3661.0, "1:01:01")] {
            XCTAssertEqual(MediaTechnicalInfo(durationSeconds: seconds).formattedDuration, expected)
        }
    }

    func testInvalidDurationDoesNotOverflow() {
        let durations: [Double?] = [nil, 0, -1, .nan, .infinity, -.infinity,
                                    Double.greatestFiniteMagnitude, Double(Int.max)]
        for duration in durations {
            XCTAssertNil(MediaTechnicalInfo(durationSeconds: duration).formattedDuration)
        }
    }

    func testLargeHoursDoNotTruncateTo32Bits() {
        let hours = Int64(Int32.max) + 1
        let info = MediaTechnicalInfo(durationSeconds: Double(hours * 3600 + 61))
        XCTAssertEqual(info.formattedDuration, "2147483648:01:01")
    }
}
