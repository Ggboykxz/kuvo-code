import Foundation
import Testing
@testable import KuvoLink

/// An engine in memory, through URLProtocol: answers with what it was asked, or an event stream.
final class FakeEngine: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var asked: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "engine.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.asked.append(request)
        let stream = request.url?.path() == "/api/event"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": stream ? "text/event-stream" : "application/json", "Set-Cookie": "no=thanks",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if stream {
            client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"server.connected\"}\n\ndata: {\"type\":\"server.heartbeat\"}\n\n".utf8))
        } else {
            client?.urlProtocol(self, didLoad: Data(#"{"path":"\#(request.url!.absoluteString)"}"#.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct EngineRoutesTests {
    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeEngine.self]
        return URLSession(configuration: configuration)
    }()
    let base = URL(string: "http://engine.test:4096/")!

    private func collect(_ stream: AsyncThrowingStream<LinkResponsePart, Error>) async throws -> (Int, [String: String], [Data]) {
        var status = 0, headers: [String: String] = [:], pieces: [Data] = []
        for try await part in stream {
            switch part {
            case .head(let s, let h): (status, headers) = (s, h)
            case .body(let data): pieces.append(data)
            }
        }
        return (status, headers, pieces)
    }

    @Test func passesRequestsWithTheEnginesPassword() async throws {
        FakeEngine.asked = []
        let request = LinkRequest(method: "POST", path: "api/session/ses_1/prompt?x=1", headers: ["X-Opencode-Directory": "/p", "Authorization": "Basic forged", "Cookie": "c"], body: Data("{}".utf8))
        let (status, headers, pieces) = try await collect(EngineRoutes.forward(request, to: base, password: "s3cret", session: session))
        #expect(status == 200)
        #expect(headers == ["content-type": "application/json"])
        #expect(String(decoding: pieces.reduce(Data(), +), as: UTF8.self).contains("api/session/ses_1/prompt?x=1"))
        let asked = try #require(FakeEngine.asked.last)
        #expect(asked.httpMethod == "POST")
        #expect(asked.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("opencode:s3cret".utf8).base64EncodedString())
        #expect(asked.value(forHTTPHeaderField: "x-opencode-directory") == "/p")
        #expect(asked.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func refusesWhatIsNotOnTheList() async throws {
        FakeEngine.asked = []
        let (status, _, _) = try await collect(EngineRoutes.forward(LinkRequest(path: "api/credential"), to: base, password: "s", session: session))
        #expect(status == 403)
        #expect(FakeEngine.asked.isEmpty)
    }

    @Test func eventsGoOneByOne() async throws {
        let (_, headers, pieces) = try await collect(EngineRoutes.forward(LinkRequest(path: "api/event"), to: base, password: nil, session: session))
        #expect(headers["content-type"] == "text/event-stream")
        #expect(pieces.count == 2)
        #expect(String(decoding: pieces[0], as: UTF8.self) == "data: {\"type\":\"server.connected\"}\n\n")
    }
}
