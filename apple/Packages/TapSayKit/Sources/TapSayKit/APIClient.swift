import Foundation
import Security

public struct APIError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// OpenAI 相容的 `/audio/transcriptions`、`/chat/completions`、`/models`。
/// Endpoint 填 base URL（https://api.openai.com/v1）或完整網址都可以。
public final class APIClient {
    public static let sttTimeout: TimeInterval = 120
    public static let llmTimeout: TimeInterval = 120
    public static let modelsTimeout: TimeInterval = 15

    private let session: URLSession

    public init(extraCAPEM: String = "", insecureTLS: Bool = false, protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let trust = TrustDelegate(anchors: TrustDelegate.certificates(fromPEM: extraCAPEM), insecure: insecureTLS)
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    public convenience init(settings: AppSettings) {
        self.init(extraCAPEM: settings.extraCAPEM, insecureTLS: settings.insecureTLS)
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - URL

    public static func url(_ endpoint: String, _ path: String) throws -> URL {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw APIError("尚未設定 Endpoint") }
        let full = base.hasSuffix(path) ? base : base + path  // 使用者填了完整網址就直接用
        guard let url = URL(string: full), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            throw APIError("Endpoint 格式不正確：\(endpoint)")
        }
        return url
    }

    // MARK: - API

    public func transcribe(endpoint: String, apiKey: String, model: String, language: String = "",
                           audio: Data, filename: String = "audio.wav", mimeType: String = "audio/wav") async throws -> String {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw APIError("尚未設定 STT Model") }
        var fields = ["model": model]
        let lang = language.trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty { fields["language"] = lang }
        let (body, contentType) = Multipart.encode(fields: fields, fileField: "file", filename: filename,
                                                   mimeType: mimeType, content: audio)
        var req = try request(Self.url(endpoint, "/audio/transcriptions"), apiKey: apiKey, timeout: Self.sttTimeout)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let json = try await send(req)
        guard let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw APIError("STT 沒有回傳文字")
        }
        return text
    }

    public func refine(endpoint: String, apiKey: String, model: String, prompt: String, text: String) async throws -> String {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw APIError("尚未設定 LLM Model") }
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text],
            ],
        ]
        var req = try request(Self.url(endpoint, "/chat/completions"), apiKey: apiKey, timeout: Self.llmTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let json = try await send(req)
        return try Self.chatContent(json)
    }

    public func listModels(endpoint: String, apiKey: String) async throws -> [String] {
        let req = try request(Self.url(endpoint, "/models"), apiKey: apiKey, timeout: Self.modelsTimeout)
        let json = try await send(req)
        guard let items = json["data"] as? [[String: Any]] else {
            throw APIError("Endpoint 沒有回傳模型清單")
        }
        return items.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: - 內部

    static func chatContent(_ json: [String: Any]) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw APIError("LLM 回應格式不正確") }
        var content: String?
        if let s = message["content"] as? String {
            content = s
        } else if let parts = message["content"] as? [[String: Any]] {  // 少數 provider 回 content parts
            content = parts.compactMap { $0["text"] as? String }.joined()
        }
        guard let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw APIError("LLM 沒有回傳文字")
        }
        return text
    }

    private func request(_ url: URL, apiKey: String, timeout: TimeInterval) throws -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw Self.describe(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError("HTTP \(http.statusCode): \(detail.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : detail)")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return ["text": text]  // 有些 STT endpoint 直接回純文字
        }
        guard let dict = obj as? [String: Any] else { throw APIError("回應格式不正確") }
        if let err = dict["error"] {
            if let e = err as? [String: Any], let msg = e["message"] as? String { throw APIError(msg) }
            throw APIError("\(err)")
        }
        return dict
    }

    static func describe(_ error: URLError) -> APIError {
        switch error.code {
        case .timedOut:
            return APIError("連線逾時")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return APIError("憑證驗證失敗：\(error.localizedDescription)（受限網路請在設定填「額外信任的 CA 憑證」，或開啟「關閉 TLS 憑證驗證」）")
        case .appTransportSecurityRequiresSecureConnection:
            return APIError("系統拒絕非 HTTPS 連線：\(error.localizedDescription)")
        default:
            return APIError("連線失敗：\(error.localizedDescription)")
        }
    }
}

// MARK: - multipart/form-data

public enum Multipart {
    public static func encode(fields: [String: String], fileField: String, filename: String,
                              mimeType: String, content: Data, boundary: String = UUID().uuidString) -> (Data, String) {
        var out = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            out.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        out.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        out.append(content)
        out.append("\r\n--\(boundary)--\r\n")
        return (out, "multipart/form-data; boundary=\(boundary)")
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

// MARK: - TLS：額外信任的 CA／關閉驗證

final class TrustDelegate: NSObject, URLSessionDelegate {
    let anchors: [SecCertificate]
    let insecure: Bool

    init(anchors: [SecCertificate], insecure: Bool) {
        self.anchors = anchors
        self.insecure = insecure
    }

    /// 從 PEM 文字取出所有憑證。不是合法 PEM 的部分直接略過。
    static func certificates(fromPEM pem: String) -> [SecCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var result: [SecCertificate] = []
        var rest = Substring(pem)
        while let b = rest.range(of: begin), let e = rest.range(of: end, range: b.upperBound..<rest.endIndex) {
            let body = rest[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)), let cert = SecCertificateCreateWithData(nil, der as CFData) {
                result.append(cert)
            }
            rest = rest[e.upperBound...]
        }
        return result
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              insecure || !anchors.isEmpty
        else { return completionHandler(.performDefaultHandling, nil) }

        if insecure {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        // 「加上去」不是「取代」：AnchorCertificatesOnly(false) 讓系統原本的根憑證照樣有效。
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
