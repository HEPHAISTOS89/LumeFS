import XCTest
@testable import LumeFS

final class MetricFormatterTests: XCTestCase {
    func testFormatsGigabytesPerSecond() {
        XCTAssertEqual(MetricFormatter.throughput(2_500_000_000), "2.50 GB/s")
    }

    func testFormatsMegabytesPerSecond() {
        XCTAssertEqual(MetricFormatter.throughput(25_000_000), "25.0 MB/s")
    }
}
