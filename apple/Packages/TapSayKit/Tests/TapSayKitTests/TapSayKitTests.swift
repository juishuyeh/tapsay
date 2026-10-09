import XCTest
@testable import TapSayKit

/// 攔截 URLSession 的請求，回假資料。
final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

final class APIClientTests: XCTestCase {
    var client: APIClient!

    override func setUp() {
        client = APIClient(protocolClasses: [StubProtocol.self])
        StubProtocol.handler = nil
    }

    func testURLJoinsBaseAndKeepsFullURL() throws {
        XCTAssertEqual(try APIClient.url("https://api.openai.com/v1/", "/models").absoluteString,
                       "https://api.openai.com/v1/models")
        XCTAssertEqual(try APIClient.url(" http://localhost:4000/v1/chat/completions ", "/chat/completions").absoluteString,
                       "http://localhost:4000/v1/chat/completions")
        XCTAssertThrowsError(try APIClient.url("", "/models"))
        XCTAssertThrowsError(try APIClient.url("ftp://x", "/models"))
    }

    func testTranscribeSendsMultipartAndKey() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"text":" 你好 "}"#.utf8)) }
        let text = try await client.transcribe(endpoint: "https://stt.example/v1", apiKey: "sk-1",
                                               model: "whisper-1", language: "zh", audio: Data([1, 2, 3]))
        XCTAssertEqual(text, "你好")
        let req = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://stt.example/v1/audio/transcriptions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = String(decoding: try XCTUnwrap(StubProtocol.lastBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(body.contains("filename=\"audio.wav\""))
    }

    func testTranscribeAcceptsPlainText() async throws {
        StubProtocol.handler = { _ in (200, Data("純文字回應".utf8)) }
        let text = try await client.transcribe(endpoint: "https://x/v1", apiKey: "", model: "m", audio: Data())
        XCTAssertEqual(text, "純文字回應")
        XCTAssertNil(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testRefineParsesStringAndParts() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"整理好了"}}]}"#.utf8)) }
        let a = try await client.refine(endpoint: "https://x/v1", apiKey: "k", model: "m", prompt: "p", text: "t")
        XCTAssertEqual(a, "整理好了")
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(StubProtocol.lastBody)) as? [String: Any]
        XCTAssertEqual(sent?["model"] as? String, "m")

        StubProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"A"},{"text":"B"}]}}]}"#.utf8)) }
        let b = try await client.refine(endpoint: "https://x/v1", apiKey: "k", model: "m", prompt: "p", text: "t")
        XCTAssertEqual(b, "AB")
    }

    func testErrorsAreReadable() async {
        StubProtocol.handler = { _ in (401, Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
        do {
            _ = try await client.listModels(endpoint: "https://x/v1", apiKey: "k")
            XCTFail("應該要丟錯")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("HTTP 401"), error.localizedDescription)
        }

        StubProtocol.handler = { _ in (200, Data(#"{"error":{"message":"quota"}}"#.utf8)) }
        do {
            _ = try await client.refine(endpoint: "https://x/v1", apiKey: "k", model: "m", prompt: "p", text: "t")
            XCTFail("應該要丟錯")
        } catch {
            XCTAssertEqual(error.localizedDescription, "quota")
        }

        do {
            _ = try await client.refine(endpoint: "https://x/v1", apiKey: "k", model: " ", prompt: "p", text: "t")
            XCTFail("應該要丟錯")
        } catch {
            XCTAssertEqual(error.localizedDescription, "尚未設定 LLM Model")
        }
    }

    func testListModelsSorted() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":[{"id":"b"},{"id":"a"},{"x":1}]}"#.utf8)) }
        let models = try await client.listModels(endpoint: "https://x/v1", apiKey: "")
        XCTAssertEqual(models, ["a", "b"])
    }
}

final class CoreTests: XCTestCase {
    func testWAVHeader() {
        let wav = WAV.encode(pcm16: Data(count: 32000), sampleRate: 16000)
        XCTAssertEqual(wav.count, 44 + 32000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        let rate = wav[24..<28].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(rate, 16000)
    }

    func testSettingsFillMissingFields() throws {
        let json = #"{"stt":{"endpoint":"https://groq/v1","model":"w"},"autoPaste":false,"unknown":1}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.stt.endpoint, "https://groq/v1")
        XCTAssertFalse(s.autoPaste)
        XCTAssertEqual(s.llm, AppSettings().llm)
        XCTAssertEqual(s.prompt, AppSettings.defaultPrompt)
        XCTAssertEqual(s.hotkey, .default)
    }

    func testSettingsRoundTrip() throws {
        var s = AppSettings()
        s.llm.model = "x"
        s.insecureTLS = true
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testPEMParsingSkipsGarbage() {
        XCTAssertTrue(TrustDelegate.certificates(fromPEM: "").isEmpty)
        XCTAssertTrue(TrustDelegate.certificates(fromPEM: "-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----").isEmpty)
    }

    func testBridgeResultIsTakenOnce() {
        SessionBridge.publishResult("哈囉")
        XCTAssertEqual(SessionBridge.takeResult(), "哈囉")
        XCTAssertNil(SessionBridge.takeResult())
        XCTAssertEqual(SessionBridge.state, .done)
    }
}
