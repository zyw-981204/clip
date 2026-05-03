import XCTest
@testable import Clip

final class D1BackendTests: XCTestCase {
    var session: URLSession!
    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProto.self]
        session = URLSession(configuration: cfg)
    }
    override func tearDown() { StubProto.handler = nil; super.tearDown() }

    func makeBackend() -> D1Backend {
        D1Backend(accountID: "acct", databaseID: "db",
                  apiToken: "tok", session: session)
    }

    /// Helper: wrap a SQL response in the D1 REST envelope.
    func wrapResults(_ rows: [[String: Any]], rowsWritten: Int = 0) -> Data {
        let env: [String: Any] = [
            "result": [[
                "results": rows,
                "success": true,
                "meta": ["rows_read": rows.count, "rows_written": rowsWritten,
                         "changes": rowsWritten, "last_row_id": 0]
            ]],
            "errors": [], "messages": [], "success": true
        ]
        return try! JSONSerialization.data(withJSONObject: env)
    }

    func testQueryClipByHmacReturnsDeleted() async throws {
        StubProto.handler = { req in
            let body = self.wrapResults([["id": "uuid1", "deleted": 1]])
            return (HTTPURLResponse(url: req.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, body)
        }
        let r = try await makeBackend().queryClipByHmac("hmac1")
        XCTAssertEqual(r?.id, "uuid1")
        XCTAssertEqual(r?.deleted, true)
    }

    func testQueryClipByHmacReturnsNilOnEmpty() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             self.wrapResults([]))
        }
        let r = try await makeBackend().queryClipByHmac("nope")
        XCTAssertNil(r)
    }

    func testUpsertClipReturnsServerUpdatedAt() async throws {
        var captured: URLRequest?
        var body: Data?
        StubProto.handler = { req in
            captured = req
            // Capture sent body for assertions
            if let s = req.httpBodyStream {
                let buf = NSMutableData()
                s.open(); defer { s.close() }
                var b = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable {
                    let n = s.read(&b, maxLength: b.count)
                    if n > 0 { buf.append(b, length: n) }
                    if n <= 0 { break }
                }
                body = buf as Data
            } else { body = req.httpBody }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.wrapResults([["updated_at": 12345]], rowsWritten: 1))
        }
        let row = CloudRow(id: "id1", hmac: "h1", ciphertext: Data([0x01]),
                           kind: "text", blobKey: nil, byteSize: 5,
                           deviceID: "DEV", createdAt: 100, updatedAt: 0,
                           deleted: false)
        let updated = try await makeBackend().upsertClip(row)
        XCTAssertEqual(updated, 12345)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertTrue(captured?.url?.absoluteString.contains("/d1/database/db/query") ?? false)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        // Body must reference INSERT ... ON CONFLICT and unixepoch()
        let s = String(data: body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("INSERT INTO clips"))
        XCTAssertTrue(s.contains("ON CONFLICT(id)"))
        XCTAssertTrue(s.contains("unixepoch()"))
    }

    func testQueryClipsChangedSinceCompositeCursorSQL() async throws {
        var bodyStr = ""
        StubProto.handler = { req in
            if let b = req.httpBody {
                bodyStr = String(data: b, encoding: .utf8) ?? ""
            } else if let s = req.httpBodyStream {
                let buf = NSMutableData()
                s.open(); defer { s.close() }
                var b = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable {
                    let n = s.read(&b, maxLength: b.count)
                    if n > 0 { buf.append(b, length: n) }
                    if n <= 0 { break }
                }
                bodyStr = String(data: buf as Data, encoding: .utf8) ?? ""
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.wrapResults([]))
        }
        _ = try await makeBackend().queryClipsChangedSince(
            cursor: CloudCursor(updatedAt: 100, id: "abc"), limit: 50)
        // SQL must contain composite WHERE (fix A) + ORDER BY updated_at, id
        XCTAssertTrue(bodyStr.contains("WHERE updated_at > "))
        XCTAssertTrue(bodyStr.contains("OR (updated_at = "))
        XCTAssertTrue(bodyStr.contains("ORDER BY updated_at, id"))
    }

    func testPutConfigIfAbsentReportsRowsWritten() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             self.wrapResults([], rowsWritten: 1))
        }
        let won = try await makeBackend().putConfigIfAbsent(key: "k", value: "v")
        XCTAssertTrue(won)
    }

    func testPutConfigIfAbsentReportsExisting() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             self.wrapResults([], rowsWritten: 0))
        }
        let won = try await makeBackend().putConfigIfAbsent(key: "k", value: "v")
        XCTAssertFalse(won)
    }
}
