import Foundation

/// Target macOS desktop browser for opening links and inspecting the active tab.
public enum DesktopBrowserTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemDefault = "system_default"
    case safari = "safari"
    case chrome = "chrome"
    case arc = "arc"
    case brave = "brave"
    case edge = "edge"
    case firefox = "firefox"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .systemDefault: return "System Default"
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .arc: return "Arc"
        case .brave: return "Brave Browser"
        case .edge: return "Microsoft Edge"
        case .firefox: return "Firefox"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .systemDefault: return nil
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .arc: return "company.thebrowser.Browser"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    public var appleScriptAppName: String? {
        switch self {
        case .systemDefault: return nil
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .arc: return "Arc"
        case .brave: return "Brave Browser"
        case .edge: return "Microsoft Edge"
        case .firefox: return nil
        }
    }
}

/// Persisted desktop browser integration preferences in `WorkspaceSnapshot`.
public struct DesktopBrowserConfig: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var preferredBrowser: DesktopBrowserTarget
    public var requireApprovalToOpenLinks: Bool

    public init(
        isEnabled: Bool = true,
        preferredBrowser: DesktopBrowserTarget = .systemDefault,
        requireApprovalToOpenLinks: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.preferredBrowser = preferredBrowser
        self.requireApprovalToOpenLinks = requireApprovalToOpenLinks
    }
}

public struct BrowserSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String = "") {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public struct BrowserLink: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct BrowserPageSnapshot: Codable, Sendable, Equatable {
    public let url: String
    public let title: String
    public let textExcerpt: String
    public let links: [BrowserLink]

    public init(url: String, title: String, textExcerpt: String, links: [BrowserLink] = []) {
        self.url = url
        self.title = title
        self.textExcerpt = textExcerpt
        self.links = links
    }
}

public struct BrowserActiveTab: Codable, Sendable, Equatable {
    public let browserName: String
    public let title: String
    public let url: String

    public init(browserName: String, title: String, url: String) {
        self.browserName = browserName
        self.title = title
        self.url = url
    }
}

public enum DesktopBrowserError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case missingArgument(String)
    case httpError(statusCode: Int)
    case processError(String)
    case noActiveBrowserTab

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "Blocked or invalid URL '\(raw)'. Only http:// and https:// URLs are permitted."
        case .missingArgument(let name):
            return "Missing required browser tool argument '\(name)'."
        case .httpError(let statusCode):
            return "Web request returned HTTP \(statusCode)."
        case .processError(let message):
            return message
        case .noActiveBrowserTab:
            return "No active Safari, Chrome, Arc, Brave, or Edge browser tab was found."
        }
    }
}

/// Bridges Brok Bot's BYOK LLM tool calls to web search, page extraction, and the user's macOS desktop browser.
public final class DesktopBrowserBridge: Sendable {
    public static let toolPrefix = "browser_"

    public static let toolDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "browser_web_search",
            description: "Search the web for current information and return titles, URLs, and snippets.",
            jsonSchemaParameters: """
            {"type":"object","required":["query"],"properties":{"query":{"type":"string","description":"Web search query"},"maxResults":{"type":"integer","description":"Maximum results to return (1-10)","default":5}}}
            """
        ),
        ToolDefinition(
            name: "browser_fetch_page",
            description: "Fetch and extract readable text and links from an http/https web page.",
            jsonSchemaParameters: """
            {"type":"object","required":["url"],"properties":{"url":{"type":"string","description":"HTTP or HTTPS URL to read"},"maxChars":{"type":"integer","description":"Maximum characters of page text to return (200-12000)","default":4000}}}
            """
        ),
        ToolDefinition(
            name: "browser_open_url",
            description: "Open an http/https link directly in the user's macOS desktop browser (System Default, Safari, Chrome, Arc, Brave, Edge, or Firefox).",
            jsonSchemaParameters: """
            {"type":"object","required":["url"],"properties":{"url":{"type":"string","description":"HTTP or HTTPS URL to open on the user's desktop browser"},"browser":{"type":"string","description":"Optional target browser: system_default, safari, chrome, arc, brave, edge, or firefox"}}}
            """
        ),
        ToolDefinition(
            name: "browser_get_active_tab",
            description: "Inspect the URL and title of the active tab in the user's macOS desktop browser.",
            jsonSchemaParameters: """
            {"type":"object","properties":{"browser":{"type":"string","description":"Optional target browser: system_default, safari, chrome, arc, brave, or edge"}}}
            """
        )
    ]

    public typealias OpenURLHandler = @Sendable (URL, DesktopBrowserTarget) async throws -> String
    public typealias ActiveTabReader = @Sendable (DesktopBrowserTarget) async throws -> BrowserActiveTab

    private let urlSession: URLSession
    private let openURLHandler: OpenURLHandler?
    private let activeTabReader: ActiveTabReader?

    public init(
        urlSession: URLSession = .shared,
        openURLHandler: OpenURLHandler? = nil,
        activeTabReader: ActiveTabReader? = nil
    ) {
        self.urlSession = urlSession
        self.openURLHandler = openURLHandler
        self.activeTabReader = activeTabReader
    }

    // MARK: - URL Validation & HTML Parsing

    public static func validateHTTPURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DesktopBrowserError.invalidURL(raw)
        }
        let candidateString: String
        if trimmed.contains("://") {
            candidateString = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            candidateString = "https://\(trimmed)"
        } else {
            throw DesktopBrowserError.invalidURL(raw)
        }

        guard let url = URL(string: candidateString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            throw DesktopBrowserError.invalidURL(raw)
        }
        return url
    }

    public static func parseDuckDuckGoHTML(_ html: String, maxResults: Int = 5) -> [BrowserSearchResult] {
        let limit = max(1, min(maxResults, 10))
        let anchorPattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        let snippetPattern = #"<(?:a|div|span)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</(?:a|div|span)>"#

        guard let anchorRegex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive]) else {
            return []
        }
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive])
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)
        let anchorMatches = anchorRegex.matches(in: html, options: [], range: fullRange)
        let snippetMatches = snippetRegex?.matches(in: html, options: [], range: fullRange) ?? []

        var results: [BrowserSearchResult] = []
        var seenURLs: Set<String> = []

        for (index, match) in anchorMatches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            let rawHref = decodeHTMLEntities(nsHTML.substring(with: match.range(at: 1)))
            let resolvedURLString = unwrapDuckDuckGoRedirect(rawHref)
            guard let validURL = try? validateHTTPURL(resolvedURLString) else { continue }
            if seenURLs.contains(validURL.absoluteString) { continue }

            let rawTitle = nsHTML.substring(with: match.range(at: 2))
            let title = collapseWhitespace(decodeHTMLEntities(stripHTMLTags(rawTitle)))
            guard !title.isEmpty else { continue }

            var snippet = ""
            if index < snippetMatches.count, snippetMatches[index].numberOfRanges >= 2 {
                let rawSnippet = nsHTML.substring(with: snippetMatches[index].range(at: 1))
                snippet = collapseWhitespace(decodeHTMLEntities(stripHTMLTags(rawSnippet)))
            }

            seenURLs.insert(validURL.absoluteString)
            results.append(BrowserSearchResult(title: title, url: validURL.absoluteString, snippet: snippet))
            if results.count >= limit { break }
        }

        return results
    }

    public static func parseHTMLPage(url: URL, html: String, maxChars: Int = 4000) -> BrowserPageSnapshot {
        let clampedChars = max(200, min(maxChars, 12_000))
        let title = extractFirstMatch(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, in: html)
            .map { collapseWhitespace(decodeHTMLEntities(stripHTMLTags($0))) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (url.host ?? url.absoluteString)

        let links = extractLinks(from: html, baseURL: url, maxLinks: 12)

        var cleaned = html
        for tag in ["script", "style", "noscript", "svg"] {
            cleaned = replacingRegex(
                pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
                in: cleaned,
                with: " "
            )
        }
        cleaned = replacingRegex(pattern: "<[^>]+>", in: cleaned, with: " ")
        cleaned = collapseWhitespace(decodeHTMLEntities(cleaned))

        let excerpt: String
        if cleaned.count > clampedChars {
            excerpt = String(cleaned.prefix(clampedChars)) + "…"
        } else {
            excerpt = cleaned
        }

        return BrowserPageSnapshot(
            url: url.absoluteString,
            title: title,
            textExcerpt: excerpt,
            links: links
        )
    }

    // MARK: - Execution Methods

    public func searchWeb(query: String, maxResults: Int = 5) async throws -> [BrowserSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DesktopBrowserError.missingArgument("query")
        }
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            throw DesktopBrowserError.invalidURL("https://html.duckduckgo.com/html/")
        }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else {
            throw DesktopBrowserError.invalidURL("https://html.duckduckgo.com/html/")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DesktopBrowserError.httpError(statusCode: http.statusCode)
        }
        let html = String(decoding: data, as: UTF8.self)
        return Self.parseDuckDuckGoHTML(html, maxResults: maxResults)
    }

    public func fetchPage(urlString: String, maxChars: Int = 4000) async throws -> BrowserPageSnapshot {
        let url = try Self.validateHTTPURL(urlString)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DesktopBrowserError.httpError(statusCode: http.statusCode)
        }
        let html = String(decoding: data, as: UTF8.self)
        return Self.parseHTMLPage(url: url, html: html, maxChars: maxChars)
    }

    public func openURL(urlString: String, target: DesktopBrowserTarget) async throws -> String {
        let url = try Self.validateHTTPURL(urlString)
        if let openURLHandler {
            return try await openURLHandler(url, target)
        }
        return try await Self.launchDesktopBrowser(url: url, target: target)
    }

    public func getActiveTab(target: DesktopBrowserTarget) async throws -> BrowserActiveTab {
        if let activeTabReader {
            return try await activeTabReader(target)
        }
        return try await Self.readActiveTabViaAppleScript(target: target)
    }

    /// Executes a `browser_*` tool call emitted by `BYOKModelClient`.
    public func executeToolCall(
        record: ToolCallRecord,
        config: DesktopBrowserConfig
    ) async -> (outputText: String, isError: Bool, openedURL: String?, activeTab: BrowserActiveTab?) {
        let args = JSONValue.decodeObject(from: record.argumentsJSON)

        do {
            switch record.name {
            case "browser_web_search":
                guard let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty else {
                    throw DesktopBrowserError.missingArgument("query")
                }
                let maxResults = args["maxResults"]?.intValue ?? 5
                let results = try await searchWeb(query: query, maxResults: maxResults)
                if results.isEmpty {
                    return ("No web search results found for '\(query)'.", false, nil, nil)
                }
                let formatted = results.enumerated().map { idx, item in
                    let snippetLine = item.snippet.isEmpty ? "" : "\n   \(item.snippet)"
                    return "\(idx + 1). \(item.title)\n   \(item.url)\(snippetLine)"
                }.joined(separator: "\n")
                return ("Web search results for '\(query)':\n\(formatted)", false, nil, nil)

            case "browser_fetch_page":
                guard let urlStr = args["url"]?.stringValue, !urlStr.isEmpty else {
                    throw DesktopBrowserError.missingArgument("url")
                }
                let maxChars = args["maxChars"]?.intValue ?? 4000
                let snapshot = try await fetchPage(urlString: urlStr, maxChars: maxChars)
                let linksText = snapshot.links.isEmpty
                    ? ""
                    : "\n\nLinks:\n" + snapshot.links.map { "- \($0.title): \($0.url)" }.joined(separator: "\n")
                let text = "Page: \(snapshot.title)\nURL: \(snapshot.url)\n\n\(snapshot.textExcerpt)\(linksText)"
                return (text, false, nil, nil)

            case "browser_open_url":
                guard let urlStr = args["url"]?.stringValue, !urlStr.isEmpty else {
                    throw DesktopBrowserError.missingArgument("url")
                }
                let target = args["browser"]?.stringValue.flatMap(DesktopBrowserTarget.init(rawValue:))
                    ?? config.preferredBrowser
                let opened = try await openURL(urlString: urlStr, target: target)
                return ("Opened \(opened) in \(target.displayName).", false, opened, nil)

            case "browser_get_active_tab":
                let target = args["browser"]?.stringValue.flatMap(DesktopBrowserTarget.init(rawValue:))
                    ?? config.preferredBrowser
                let tab = try await getActiveTab(target: target)
                return ("Active tab in \(tab.browserName): \(tab.title)\nURL: \(tab.url)", false, nil, tab)

            default:
                return ("Unknown desktop browser tool '\(record.name)'.", true, nil, nil)
            }
        } catch {
            return ("Browser tool '\(record.name)' failed: \(error.localizedDescription)", true, nil, nil)
        }
    }

    // MARK: - macOS Desktop Process Helpers

    private static func launchDesktopBrowser(url: URL, target: DesktopBrowserTarget) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            if let bundleID = target.bundleIdentifier {
                process.arguments = ["-b", bundleID, url.absoluteString]
            } else {
                process.arguments = [url.absoluteString]
            }
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if target.bundleIdentifier != nil {
                    // Fallback to system default if requested browser isn't installed
                    let fallback = Process()
                    fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    fallback.arguments = [url.absoluteString]
                    try fallback.run()
                    fallback.waitUntilExit()
                    if fallback.terminationStatus == 0 {
                        return url.absoluteString
                    }
                }
                throw DesktopBrowserError.processError(errMsg.isEmpty ? "Failed to open \(url.absoluteString)." : errMsg)
            }
            return url.absoluteString
        }.value
    }

    private static func readActiveTabViaAppleScript(target: DesktopBrowserTarget) async throws -> BrowserActiveTab {
        try await Task.detached(priority: .userInitiated) {
            let candidates: [DesktopBrowserTarget]
            if target == .systemDefault || target == .firefox {
                candidates = [.arc, .chrome, .safari, .brave, .edge]
            } else {
                candidates = [target]
            }

            for candidate in candidates {
                guard let appName = candidate.appleScriptAppName else { continue }
                let script: String
                if candidate == .safari {
                    script = """
                    tell application "System Events"
                        if not (exists process "\(appName)") then return ""
                    end tell
                    tell application "\(appName)"
                        if (count of windows) is 0 then return ""
                        set tabURL to URL of current tab of front window
                        set tabTitle to name of current tab of front window
                        return tabURL & linefeed & tabTitle
                    end tell
                    """
                } else {
                    script = """
                    tell application "System Events"
                        if not (exists process "\(appName)") then return ""
                    end tell
                    tell application "\(appName)"
                        if (count of windows) is 0 then return ""
                        set tabURL to URL of active tab of front window
                        set tabTitle to title of active tab of front window
                        return tabURL & linefeed & tabTitle
                    end tell
                    """
                }

                if let output = runOSAScript(script), !output.isEmpty {
                    let lines = output.components(separatedBy: .newlines)
                    let urlStr = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !urlStr.isEmpty {
                        let title = lines.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? urlStr
                        return BrowserActiveTab(browserName: appName, title: title, url: urlStr)
                    }
                }
            }

            throw DesktopBrowserError.noActiveBrowserTab
        }.value
    }

    private static func runOSAScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - String & HTML Utilities

    private static func unwrapDuckDuckGoRedirect(_ href: String) -> String {
        let normalized = href.hasPrefix("//") ? "https:\(href)" : href
        if let comps = URLComponents(string: normalized),
           let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
           !uddg.isEmpty {
            return uddg
        }
        return normalized
    }

    private static func extractLinks(from html: String, baseURL: URL, maxLinks: Int) -> [BrowserLink] {
        let pattern = #"<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
        var result: [BrowserLink] = []
        var seen: Set<String> = []

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let rawHref = decodeHTMLEntities(nsHTML.substring(with: match.range(at: 1)))
            let resolvedURL: URL?
            if rawHref.hasPrefix("http://") || rawHref.hasPrefix("https://") {
                resolvedURL = try? validateHTTPURL(rawHref)
            } else if rawHref.hasPrefix("/") {
                resolvedURL = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL
            } else {
                resolvedURL = nil
            }
            guard let url = resolvedURL,
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  !seen.contains(url.absoluteString) else {
                continue
            }
            let title = collapseWhitespace(decodeHTMLEntities(stripHTMLTags(nsHTML.substring(with: match.range(at: 2)))))
            guard !title.isEmpty else { continue }
            seen.insert(url.absoluteString)
            result.append(BrowserLink(title: title, url: url.absoluteString))
            if result.count >= maxLinks { break }
        }
        return result
    }

    private static func extractFirstMatch(pattern: String, in input: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsInput = input as NSString
        guard let match = regex.firstMatch(in: input, options: [], range: NSRange(location: 0, length: nsInput.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return nsInput.substring(with: match.range(at: 1))
    }

    private static func replacingRegex(pattern: String, in input: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let range = NSRange(location: 0, length: (input as NSString).length)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }

    private static func stripHTMLTags(_ input: String) -> String {
        replacingRegex(pattern: "<[^>]+>", in: input, with: " ")
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func collapseWhitespace(_ input: String) -> String {
        input
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
