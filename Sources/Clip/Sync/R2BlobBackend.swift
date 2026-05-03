import Foundation

/// CloudSyncBlobStore implementation against Cloudflare R2 over the S3 API.
/// Only PUT / GET / DELETE blobs/<key>. No list / no head — D1 row drives
/// "what blobs exist".
final class R2BlobBackend: CloudSyncBlobStore, @unchecked Sendable {
    enum Error: Swift.Error {
        case http(status: Int, body: String)
    }

    let endpoint: URL
    let bucket: String
    let signer: S3SignerV4
    let session: URLSession

    init(endpoint: URL, bucket: String, accessKeyID: String,
         secretAccessKey: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.signer = S3SignerV4(accessKeyID: accessKeyID,
                                 secretAccessKey: secretAccessKey,
                                 region: "auto", service: "s3")
        self.session = session
    }

    private func url(for key: String) -> URL {
        endpoint.appendingPathComponent(bucket).appendingPathComponent(key)
    }

    func putBlob(key: String, body: Data) async throws {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    func getBlob(key: String) async throws -> Data? {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "GET"
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func deleteBlob(key: String) async throws {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "DELETE"
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 404 { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
