import Foundation
import os
@testable import Pinfold
import Testing

/// URLProtocol stub: answers by host so tests running in one process never collide.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
    }

    private static let stubs = OSAllocatedUnfairLock<[String: Stub]>(initialState: [:])

    static func register(_ stub: Stub, host: String) {
        stubs.withLock { $0[host] = stub }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let stub = Self.stubs.withLock({ $0[host] }),
              let response = HTTPURLResponse(
                  url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if (300 ..< 400).contains(stub.status), let location = stub.headers["Location"],
           let target = URL(string: location)
        {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct BoundedDownloaderTests {
    private func fetch(host: String, maxBytes: Int = 1000) async throws -> Data {
        try await BoundedDownloader.fetch(
            URL(string: "https://\(host)/a.png")!,
            maxBytes: maxBytes,
            timeout: 5,
            configuration: StubURLProtocol.configuration()
        )
    }

    @Test func crossHostRedirect_isRefusedWhenAsked() async throws {
        StubURLProtocol.register(.init(status: 302, headers: ["Location": "https://target.redirect.test/a.kml"]),
                                 host: "origin.redirect.test")
        StubURLProtocol.register(.init(chunks: [Data([1])]), host: "target.redirect.test")
        do {
            _ = try await BoundedDownloader.fetch(
                #require(URL(string: "https://origin.redirect.test/a.kml")), maxBytes: 100, timeout: 5,
                followCrossHostRedirects: false, configuration: StubURLProtocol.configuration()
            )
            Issue.record("expected failure")
        } catch DownloadError.redirectedToOtherHost {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func crossHostRedirect_isFollowedByDefault() async throws {
        StubURLProtocol.register(.init(status: 302, headers: ["Location": "https://target2.redirect.test/a.png"]),
                                 host: "origin2.redirect.test")
        StubURLProtocol.register(.init(chunks: [Data([7])]), host: "target2.redirect.test")
        let data = try await BoundedDownloader.fetch(
            #require(URL(string: "https://origin2.redirect.test/a.png")), maxBytes: 100, timeout: 5,
            configuration: StubURLProtocol.configuration()
        )
        #expect(data == Data([7]))
    }

    @Test func sameHostRedirect_isFollowedEvenWhenGuarded() async throws {
        StubURLProtocol.register(.init(status: 302, headers: ["Location": "https://same.redirect.test/b"]),
                                 host: "same.redirect.test")
        // Same host answers the redirect target with the same 302 stub: loop ends in an error, but
        // never as `redirectedToOtherHost`.
        do {
            _ = try await BoundedDownloader.fetch(
                #require(URL(string: "https://same.redirect.test/a")), maxBytes: 100, timeout: 5,
                followCrossHostRedirects: false, configuration: StubURLProtocol.configuration()
            )
        } catch DownloadError.redirectedToOtherHost {
            Issue.record("same-host redirect must not be refused")
        } catch {}
    }

    @Test(arguments: [404, 429, 503])
    func non2xx_throwsHTTPStatus(status: Int) async {
        let host = "status\(status).test"
        StubURLProtocol.register(.init(status: status, chunks: [Data([1, 2, 3])]), host: host)
        do {
            _ = try await fetch(host: host)
            Issue.record("expected failure")
        } catch let DownloadError.httpStatus(code) {
            #expect(code == status)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func contentLengthOverCap_isRejectedBeforeBody() async {
        let host = "declared.test"
        // Declares 5000 bytes but sends none: only the header check can reject it.
        StubURLProtocol.register(.init(headers: ["Content-Length": "5000"], chunks: []), host: host)
        do {
            _ = try await fetch(host: host)
            Issue.record("expected tooLarge")
        } catch DownloadError.tooLarge {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func bodyOverCapWithoutContentLength_isCancelled() async {
        let host = "streamed.test"
        let chunk = Data(count: 600)
        StubURLProtocol.register(.init(chunks: [chunk, chunk, chunk]), host: host)
        do {
            _ = try await fetch(host: host)
            Issue.record("expected tooLarge")
        } catch DownloadError.tooLarge {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func ok_returnsBody() async throws {
        let host = "ok.test"
        StubURLProtocol.register(.init(chunks: [Data([1, 2]), Data([3])]), host: host)
        let data = try await fetch(host: host)
        #expect(data == Data([1, 2, 3]))
    }

    @Test func transportFailure_isWrapped() async {
        do {
            _ = try await fetch(host: "unregistered.test")
            Issue.record("expected failure")
        } catch DownloadError.transport {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func nonHTTPScheme_isRejected() async throws {
        do {
            _ = try await BoundedDownloader.fetch(
                #require(URL(string: "ftp://example.com/a.png")), maxBytes: 10, timeout: 5,
                configuration: StubURLProtocol.configuration()
            )
            Issue.record("expected failure")
        } catch DownloadError.transport {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
