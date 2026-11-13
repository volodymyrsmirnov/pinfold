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
        /// Request headers that must be present; otherwise the stub fails the request.
        var requiredRequestHeaders: [String: String] = [:]
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
        for (name, value) in stub.requiredRequestHeaders where request.value(forHTTPHeaderField: name) != value {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
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

    // MARK: Conditional fetch

    private func conditional(
        host: String, etag: String? = nil, lastModified: String? = nil, maxBytes: Int = 1000,
        now: Date = .now, followCrossHost: Bool = false
    ) async throws -> ConditionalResponse {
        try await BoundedDownloader.fetchConditional(
            #require(URL(string: "https://\(host)/feed.kml")), etag: etag, lastModified: lastModified,
            maxBytes: maxBytes, timeout: 5, followCrossHostRedirects: followCrossHost,
            configuration: StubURLProtocol.configuration(), now: now
        )
    }

    @Test func conditional_sendsIfNoneMatchAndIfModifiedSince() async throws {
        let host = "cond-headers.test"
        StubURLProtocol.register(.init(
            status: 304,
            requiredRequestHeaders: ["If-None-Match": "\"abc\"", "If-Modified-Since": "Wed, 01 Jan 2025 00:00:00 GMT"]
        ), host: host)
        let response = try await conditional(host: host, etag: "\"abc\"", lastModified: "Wed, 01 Jan 2025 00:00:00 GMT")
        guard case .notModified = response.body else {
            Issue.record("expected notModified")
            return
        }
    }

    @Test func conditional_304_isNotModified() async throws {
        let host = "cond-304.test"
        StubURLProtocol.register(.init(status: 304), host: host)
        let response = try await conditional(host: host)
        guard case .notModified = response.body else {
            Issue.record("expected notModified")
            return
        }
    }

    @Test func conditional_200_returnsBodyAndHeaders() async throws {
        let host = "cond-200.test"
        StubURLProtocol.register(.init(
            headers: ["ETag": "\"v1\"", "Last-Modified": "Wed, 01 Jan 2025 00:00:00 GMT", "Cache-Control": "public, max-age=600",
                      "Expires": "Wed, 01 Jan 2025 00:01:00 GMT"],
            chunks: [Data([1, 2, 3])]
        ), host: host)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let response = try await conditional(host: host, now: now)
        guard case let .data(data) = response.body else {
            Issue.record("expected data")
            return
        }
        #expect(data == Data([1, 2, 3]))
        #expect(response.etag == "\"v1\"")
        #expect(response.lastModified == "Wed, 01 Jan 2025 00:00:00 GMT")
        #expect(response.httpExpires == now.addingTimeInterval(600))
    }

    @Test func conditional_expiresHeader_parsed() async throws {
        let host = "cond-expires.test"
        StubURLProtocol.register(.init(
            headers: ["Expires": "Wed, 01 Jan 2025 00:01:00 GMT"], chunks: [Data([1])]
        ), host: host)
        let response = try await conditional(host: host)
        #expect(response.httpExpires == Date(timeIntervalSince1970: 1_735_689_660))
    }

    @Test func conditional_500_throwsHttpStatus() async {
        let host = "cond-500.test"
        StubURLProtocol.register(.init(status: 500, chunks: [Data([1])]), host: host)
        do {
            _ = try await conditional(host: host)
            Issue.record("expected failure")
        } catch let DownloadError.httpStatus(code) {
            #expect(code == 500)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func conditional_oversize_throwsTooLarge() async {
        let host = "cond-big.test"
        StubURLProtocol.register(.init(chunks: [Data(count: 600), Data(count: 600)]), host: host)
        do {
            _ = try await conditional(host: host)
            Issue.record("expected tooLarge")
        } catch DownloadError.tooLarge {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func conditional_crossHostRedirect_refused() async {
        StubURLProtocol.register(.init(status: 302, headers: ["Location": "https://cond-target.test/a"]),
                                 host: "cond-origin.test")
        StubURLProtocol.register(.init(chunks: [Data([1])]), host: "cond-target.test")
        do {
            _ = try await conditional(host: "cond-origin.test")
            Issue.record("expected failure")
        } catch DownloadError.redirectedToOtherHost {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
