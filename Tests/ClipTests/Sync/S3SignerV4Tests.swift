import XCTest
@testable import Clip

final class S3SignerV4Tests: XCTestCase {
    func testSignReturnsExpectedHeaderShape() {
        let signer = S3SignerV4(accessKeyID: "AKIDEXAMPLE",
                                secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                region: "auto", service: "s3")
        var req = URLRequest(url: URL(string: "https://x.r2.cloudflarestorage.com/clip-sync/blobs/abc.bin")!)
        req.httpMethod = "PUT"
        let date = ISO8601DateFormatter().date(from: "2026-05-02T12:00:00Z")!
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD", date: date)

        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-amz-date"), "20260502T120000Z")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-amz-content-sha256"), "UNSIGNED-PAYLOAD")
        guard let auth = signed.value(forHTTPHeaderField: "Authorization") else {
            XCTFail("missing Authorization header"); return
        }
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260502/auto/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(auth.contains("Signature="))
    }

    func testSignaturesDifferByDate() {
        let s = S3SignerV4(accessKeyID: "AK", secretAccessKey: "SK", region: "auto", service: "s3")
        let req = URLRequest(url: URL(string: "https://x/k")!)
        let r1 = s.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD",
                        date: Date(timeIntervalSince1970: 1_700_000_000))
        let r2 = s.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD",
                        date: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertNotEqual(r1.value(forHTTPHeaderField: "Authorization"),
                          r2.value(forHTTPHeaderField: "Authorization"))
    }

    func testCanonicalUriPreservesSlashes() {
        let s = S3SignerV4(accessKeyID: "AK", secretAccessKey: "SK", region: "auto", service: "s3")
        let url = URL(string: "https://x.r2.cloudflarestorage.com/clip-sync/blobs/abc.bin")!
        let signed = s.sign(request: URLRequest(url: url),
                            payloadSha256: "UNSIGNED-PAYLOAD", date: Date())
        XCTAssertEqual(signed.url?.path, "/clip-sync/blobs/abc.bin")
    }
}
