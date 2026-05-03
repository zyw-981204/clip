import XCTest
@testable import Clip

final class StubProto: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        guard let h = StubProto.handler else { return }
        let (resp, body) = h(self.request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class R2BlobBackendTests: XCTestCase {
    var session: URLSession!
    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProto.self]
        session = URLSession(configuration: cfg)
    }
    override func tearDown() { StubProto.handler = nil; super.tearDown() }

    func makeBackend() -> R2BlobBackend {
        R2BlobBackend(
            endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
            bucket: "clip-sync",
            accessKeyID: "AK",
            secretAccessKey: "SK",
            session: session)
    }

    func testPutBuildsExpectedRequest() async throws {
        var captured: URLRequest?
        StubProto.handler = { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, nil)
        }
        try await makeBackend().putBlob(key: "blobs/abc.bin", body: Data([0xAA]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://account.r2.cloudflarestorage.com/clip-sync/blobs/abc.bin")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testGetReturnsBodyOn200() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("payload".utf8))
        }
        let body = try await makeBackend().getBlob(key: "k.bin")
        XCTAssertEqual(body, Data("payload".utf8))
    }

    func testGetReturnsNilOn404() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        let got = try await makeBackend().getBlob(key: "missing.bin")
        XCTAssertNil(got)
    }

    func testDeleteIdempotentOn404() async throws {
        StubProto.handler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        try await makeBackend().deleteBlob(key: "x.bin")  // no throw on 404
    }
}
