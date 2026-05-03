import Foundation
import CryptoKit

/// AWS Signature V4 signer for S3-compatible APIs (used against R2).
/// Spec §6.5: path-style URLs, region "auto" for R2, UNSIGNED-PAYLOAD mode.
/// No third-party SDK — Foundation + CryptoKit only.
struct S3SignerV4: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let region: String
    let service: String

    func sign(request: URLRequest, payloadSha256: String, date: Date = Date()) -> URLRequest {
        var req = request
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadSha256, forHTTPHeaderField: "x-amz-content-sha256")

        let method = req.httpMethod ?? "GET"
        let url = req.url!
        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQuery = Self.canonicalQuery(url: url)
        let host = url.host ?? ""

        let headerPairs: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadSha256),
            ("x-amz-date", amzDate),
        ].sorted { $0.0 < $1.0 }
        let canonicalHeaders = headerPairs.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headerPairs.map { $0.0 }.joined(separator: ";")

        let canonicalRequest = [
            method, canonicalURI, canonicalQuery,
            canonicalHeaders, signedHeaders, payloadSha256,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let crSha = Self.sha256Hex(Data(canonicalRequest.utf8))
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, credentialScope, crSha]
            .joined(separator: "\n")

        let kDate    = Self.hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion  = Self.hmac(key: kDate, data: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, data: Data("aws4_request".utf8))
        let signature = Self.hmac(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        req.setValue("AWS4-HMAC-SHA256 " +
                     "Credential=\(accessKeyID)/\(credentialScope), " +
                     "SignedHeaders=\(signedHeaders), " +
                     "Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
        return req
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func canonicalQuery(url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        return items.sorted(by: { $0.name < $1.name }).map { item in
            "\(rfc3986Encode(item.name))=\(rfc3986Encode(item.value ?? ""))"
        }.joined(separator: "&")
    }

    private static let unreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s
    }()
    static func rfc3986Encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
