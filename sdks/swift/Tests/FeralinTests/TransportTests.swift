#if !canImport(FoundationNetworking)
import Foundation
import XCTest
@testable import Feralin

/// Sahte ağ katmanı: `URLSessionTransport` gerçek `URLSession` ve delege yolundan geçer.
private final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _starts = 0
    static var script: ((StubProtocol) -> Void)?

    static var starts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _starts
    }

    static func prepare(_ script: @escaping (StubProtocol) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _starts = 0
        self.script = script
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._starts += 1
        let script = Self.script
        Self.lock.unlock()
        script?(self)
    }

    override func stopLoading() {}
}

final class TransportTests: XCTestCase {
    private let url = URL(string: "https://collect.example.test/v1/batch")!

    private func transport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    private func request() -> TransportRequest {
        TransportRequest(url: url, body: Data("{}".utf8), headers: ["X-Feralin-Project-Key": testKey], timeout: 5)
    }

    func testRedirectIsNotFollowed() async throws {
        let target = URL(string: "https://baska.example.test/topla")!
        let location = url
        StubProtocol.prepare { stub in
            let response = HTTPURLResponse(url: location, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            stub.client?.urlProtocol(stub, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
        let response = try await transport().send(request())
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(StubProtocol.starts, 1, "anahtar başka adrese gitmemeli")
    }

    func testResponseBodyIsLimitedWhileDownloading() async throws {
        let location = url
        let chunk = Data(repeating: 0x78, count: 40 * 1024)
        StubProtocol.prepare { stub in
            let response = HTTPURLResponse(url: location, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)!
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            for _ in 0..<5 { stub.client?.urlProtocol(stub, didLoad: chunk) }
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
        let response = try await transport().send(request())
        XCTAssertEqual(response.status, 202)
        XCTAssertEqual(response.body.count, URLSessionTransport.maxResponseBody)
    }

    func testSmallBodyAndHeadersArePreserved() async throws {
        let location = url
        StubProtocol.prepare { stub in
            let response = HTTPURLResponse(url: location, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "7"])!
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocol(stub, didLoad: Data("{}".utf8))
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
        let response = try await transport().send(request())
        XCTAssertEqual(response.status, 429)
        XCTAssertEqual(response.body, Data("{}".utf8))
        XCTAssertEqual(response.header("retry-after"), "7")
    }

    func testNetworkErrorBecomesTransportError() async {
        StubProtocol.prepare { stub in
            stub.client?.urlProtocol(stub, didFailWithError: URLError(.notConnectedToInternet))
        }
        do {
            _ = try await transport().send(request())
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertTrue(error is TransportError)
        }
    }
}
#endif
