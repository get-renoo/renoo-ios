import XCTest
@testable import Renoo

final class IngestEndpointTests: XCTestCase {
    private func url(_ base: String, insecure: Bool = false) -> Result<URL, IngestEndpoint.Problem> {
        IngestEndpoint.eventsURL(base: URL(string: base)!, allowInsecureHTTP: insecure)
    }

    func testAppendsVersionedPath() {
        XCTAssertEqual(try url("https://ingest.example.com").get().absoluteString, "https://ingest.example.com/events/sdk")
    }

    func testToleratesTrailingSlashes() {
        XCTAssertEqual(try url("https://ingest.example.com/").get().absoluteString, "https://ingest.example.com/events/sdk")
        XCTAssertEqual(try url("https://ingest.example.com//").get().absoluteString, "https://ingest.example.com/events/sdk")
    }

    func testKeepsBasePathAndPort() {
        XCTAssertEqual(try url("https://example.com:8443/api/").get().absoluteString, "https://example.com:8443/api/events/sdk")
    }

    func testHTTPIsRejectedByDefault() {
        XCTAssertEqual(url("http://localhost:8787"), .failure(.insecureHTTP))
    }

    func testHTTPIsAcceptedWithTheDebugFlag() {
        XCTAssertEqual(try url("http://localhost:8787", insecure: true).get().absoluteString, "http://localhost:8787/events/sdk")
    }

    func testOtherSchemesAreRejectedEvenWithTheDebugFlag() {
        XCTAssertEqual(url("ftp://example.com", insecure: true), .failure(.unsupportedScheme))
        XCTAssertEqual(url("ws://example.com", insecure: true), .failure(.unsupportedScheme))
        XCTAssertEqual(url("file:///tmp/x", insecure: true), .failure(.unsupportedScheme))
    }

    func testRejectsMissingHostQueryAndCredentials() {
        XCTAssertEqual(url("https:///v1"), .failure(.missingHost))
        XCTAssertEqual(url("https://example.com?x=1"), .failure(.hasQueryOrFragment))
        XCTAssertEqual(url("https://example.com#frag"), .failure(.hasQueryOrFragment))
        XCTAssertEqual(url("https://user:pass@example.com"), .failure(.hasCredentials))
    }

    func testHealthCheckAndOffersShareTheBase() throws {
        let urls = try IngestEndpoint.urls(base: URL(string: "https://example.com/api/")!, allowInsecureHTTP: false).get()
        XCTAssertEqual(urls.events.absoluteString, "https://example.com/api/events/sdk")
        XCTAssertEqual(urls.healthCheck.absoluteString, "https://example.com/api/health-check")
        XCTAssertEqual(urls.offers.absoluteString, "https://example.com/api/offers")
        XCTAssertEqual(IngestEndpoint.urls(base: URL(string: "http://example.com")!, allowInsecureHTTP: false), .failure(.insecureHTTP))
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertNoThrow(try url("HTTPS://ingest.example.com").get())
    }
}

final class GzipTests: XCTestCase {
    func testCRC32KnownValue() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRoundTripAndHeader() throws {
        let text = Data(String(repeating: "{\"event_id\":\"abc\",\"name\":\"screen_view\"}\n", count: 200).utf8)
        let gz = try XCTUnwrap(Gzip.compress(text))
        XCTAssertEqual(Array(gz.prefix(3)), [0x1F, 0x8B, 0x08])
        XCTAssertLessThan(gz.count, text.count)
        XCTAssertEqual(Gzip.decompress(gz), text)
    }

    func testCorruptTrailerFailsDecompression() throws {
        var gz = try XCTUnwrap(Gzip.compress(Data("hello".utf8)))
        gz[gz.count - 5] ^= 0xFF
        XCTAssertNil(Gzip.decompress(gz))
    }
}
