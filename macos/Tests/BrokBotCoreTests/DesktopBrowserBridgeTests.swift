import Foundation
import XCTest
@testable import BrokBotCore

private final class BrowserMockRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    static let shared = BrowserMockRegistry()
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }

    func handler(for host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }
}

private final class BrowserMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let handler = BrowserMockRegistry.shared.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class DesktopBrowserBridgeTests: XCTestCase {
    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BrowserMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testValidateHTTPURLAndParsers() throws {
        XCTAssertEqual(try DesktopBrowserBridge.validateHTTPURL("https://example.com/docs").absoluteString, "https://example.com/docs")
        XCTAssertEqual(try DesktopBrowserBridge.validateHTTPURL("brokbot.dev").absoluteString, "https://brokbot.dev")

        XCTAssertThrowsError(try DesktopBrowserBridge.validateHTTPURL("file:///etc/passwd"))
        XCTAssertThrowsError(try DesktopBrowserBridge.validateHTTPURL("javascript:alert(1)"))
        XCTAssertThrowsError(try DesktopBrowserBridge.validateHTTPURL("   "))

        let ddgHTML = """
        <div class="result">
          <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fblog%2F&amp;rut=1">Swift Blog &amp; News</a>
          <a class="result__snippet">Official Swift language announcements.</a>
        </div>
        """
        let results = DesktopBrowserBridge.parseDuckDuckGoHTML(ddgHTML, maxResults: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Swift Blog & News")
        XCTAssertEqual(results[0].url, "https://swift.org/blog/")
        XCTAssertEqual(results[0].snippet, "Official Swift language announcements.")

        let pageHTML = """
        <html>
          <head><title>Brok Bot Docs</title><script>console.log('secret')</script></head>
          <body>
            <h1>Hello World</h1>
            <p>Local-first desktop browser integration.</p>
            <a href="https://github.com/brok-bot">GitHub Repo</a>
          </body>
        </html>
        """
        let page = DesktopBrowserBridge.parseHTMLPage(
            url: URL(string: "https://brokbot.dev")!,
            html: pageHTML,
            maxChars: 500
        )
        XCTAssertEqual(page.title, "Brok Bot Docs")
        XCTAssertTrue(page.textExcerpt.contains("Local-first desktop browser integration."))
        XCTAssertFalse(page.textExcerpt.contains("console.log"))
        XCTAssertEqual(page.links.first?.url, "https://github.com/brok-bot")
    }

    func testDesktopBrowserToolExecutionAndSnapshotPersistence() async throws {
        let ddgHost = "html.duckduckgo.com"
        let pageHost = "docs.brokbot.local"
        defer {
            BrowserMockRegistry.shared.unregister(host: ddgHost)
            BrowserMockRegistry.shared.unregister(host: pageHost)
        }

        BrowserMockRegistry.shared.register(host: ddgHost) { request in
            let html = """
            <a class="result__a" href="https://\(pageHost)/guide">Brok Guide</a>
            <span class="result__snippet">Desktop browser workflow.</span>
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data(html.utf8))
        }

        BrowserMockRegistry.shared.register(host: pageHost) { request in
            let html = "<html><head><title>Brok Guide</title></head><body><p>Guide body text.</p></body></html>"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data(html.utf8))
        }

        let bridge = DesktopBrowserBridge(
            urlSession: makeMockedSession(),
            openURLHandler: { url, target in
                "\(url.absoluteString)@\(target.rawValue)"
            },
            activeTabReader: { target in
                BrowserActiveTab(browserName: target.displayName, title: "Active Spec", url: "https://\(pageHost)/guide")
            }
        )

        let config = DesktopBrowserConfig(isEnabled: true, preferredBrowser: .arc, requireApprovalToOpenLinks: true)

        let searchRes = await bridge.executeToolCall(
            record: ToolCallRecord(id: "t1", name: "browser_web_search", argumentsJSON: #"{"query":"brok guide"}"#),
            config: config
        )
        XCTAssertFalse(searchRes.isError)
        XCTAssertTrue(searchRes.outputText.contains("Brok Guide"))
        XCTAssertTrue(searchRes.outputText.contains("https://\(pageHost)/guide"))

        let fetchRes = await bridge.executeToolCall(
            record: ToolCallRecord(id: "t2", name: "browser_fetch_page", argumentsJSON: #"{"url":"https://docs.brokbot.local/guide"}"#),
            config: config
        )
        XCTAssertFalse(fetchRes.isError)
        XCTAssertTrue(fetchRes.outputText.contains("Guide body text."))

        let openRes = await bridge.executeToolCall(
            record: ToolCallRecord(id: "t3", name: "browser_open_url", argumentsJSON: #"{"url":"https://docs.brokbot.local/guide"}"#),
            config: config
        )
        XCTAssertFalse(openRes.isError)
        XCTAssertEqual(openRes.openedURL, "https://docs.brokbot.local/guide@arc")

        let blockedOpen = await bridge.executeToolCall(
            record: ToolCallRecord(id: "t4", name: "browser_open_url", argumentsJSON: #"{"url":"file:///etc/passwd"}"#),
            config: config
        )
        XCTAssertTrue(blockedOpen.isError)

        let tabRes = await bridge.executeToolCall(
            record: ToolCallRecord(id: "t5", name: "browser_get_active_tab", argumentsJSON: "{}"),
            config: config
        )
        XCTAssertFalse(tabRes.isError)
        XCTAssertEqual(tabRes.activeTab?.title, "Active Spec")

        let snapshot = WorkspaceSnapshot(desktopBrowserConfig: config)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.desktopBrowserConfig, config)
    }
}
