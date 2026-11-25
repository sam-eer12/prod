package org.brokbot.android.core.browser

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder

data class BrowserLink(
    val title: String,
    val url: String,
    val snippet: String = ""
)

data class BrowserPageContext(
    val url: String,
    val title: String,
    val excerpt: String
)

sealed interface BrowserCommand {
    data class Search(val query: String, val autoOpenFirst: Boolean = false) : BrowserCommand
    data class OpenUrl(val url: String) : BrowserCommand
    data object ReadCurrentPage : BrowserCommand
}

object BrowserCommandParser {
    private val openPattern = Regex(
        """(?i)^(?:open|go\s+to|visit|browse\s+to|launch)\s+([^\s]+(?:\s+[^\s]+)?)\s*$"""
    )
    private val searchAndOpenPattern = Regex(
        """(?i)^search\s+(?:and\s+open|&\s*open)\s+(?:for\s+)?(.+)$"""
    )
    private val searchPattern = Regex(
        """(?i)^(?:search(?:\s+the\s+web)?(?:\s+for)?|google|look\s+up|find\s+online)\s+(.+)$"""
    )
    private val readPagePattern = Regex(
        """(?i)^(?:read|summarize|inspect)\s+(?:this|the|current)\s+(?:page|tab|site)$|^what(?:'s| is)\s+on\s+this\s+page\??$"""
    )
    private val domainRegex = Regex("""^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(?:/.*)?$""")

    fun parse(input: String): BrowserCommand? {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return null

        if (readPagePattern.matches(trimmed)) {
            return BrowserCommand.ReadCurrentPage
        }

        searchAndOpenPattern.matchEntire(trimmed)?.let { match ->
            val query = match.groupValues[1].trim()
            if (query.isNotEmpty()) {
                return BrowserCommand.Search(query = query, autoOpenFirst = true)
            }
        }

        openPattern.matchEntire(trimmed)?.let { match ->
            val candidate = match.groupValues[1].trim()
            if (looksLikeUrlOrDomain(candidate)) {
                val normalized = normalizeUrlOrSearch(candidate)
                if (isSafeHttpUrl(normalized)) {
                    return BrowserCommand.OpenUrl(normalized)
                }
            } else {
                return BrowserCommand.Search(query = candidate, autoOpenFirst = true)
            }
        }

        searchPattern.matchEntire(trimmed)?.let { match ->
            val query = match.groupValues[1].trim()
            if (query.isNotEmpty()) {
                return BrowserCommand.Search(query = query, autoOpenFirst = false)
            }
        }

        return null
    }

    fun isSafeHttpUrl(raw: String): Boolean {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return false
        return runCatching {
            val uri = URI(trimmed)
            val scheme = uri.scheme?.lowercase()
            (scheme == "http" || scheme == "https") && !uri.host.isNullOrBlank()
        }.getOrDefault(false)
    }

    fun looksLikeUrlOrDomain(raw: String): Boolean {
        val trimmed = raw.trim()
        if (trimmed.contains(" ")) return false
        val lower = trimmed.lowercase()
        if (lower.startsWith("http://") || lower.startsWith("https://")) return true
        if (lower.contains("://")) return false
        return domainRegex.matches(trimmed)
    }

    fun normalizeUrlOrSearch(input: String): String {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return "https://duckduckgo.com"
        val lower = trimmed.lowercase()
        if (lower.startsWith("http://") || lower.startsWith("https://")) {
            return trimmed
        }
        if (looksLikeUrlOrDomain(trimmed)) {
            return "https://$trimmed"
        }
        val encoded = URLEncoder.encode(trimmed, "UTF-8")
        return "https://duckduckgo.com/?q=$encoded"
    }
}

class BrokBrowserEngine {

    suspend fun searchWeb(query: String, maxResults: Int = 5): List<BrowserLink> = withContext(Dispatchers.IO) {
        val trimmed = query.trim()
        require(trimmed.isNotEmpty()) { "Search query cannot be empty." }
        val encoded = URLEncoder.encode(trimmed, "UTF-8")
        val html = httpGet("https://html.duckduckgo.com/html/?q=$encoded")
        parseDuckDuckGoHtml(html, maxResults = maxResults)
    }

    suspend fun fetchPage(url: String, maxChars: Int = 3000): BrowserPageContext = withContext(Dispatchers.IO) {
        require(BrowserCommandParser.isSafeHttpUrl(url)) { "Only http/https URLs are permitted." }
        val html = httpGet(url)
        parseHtmlPage(url = url, html = html, maxChars = maxChars)
    }

    private fun httpGet(urlString: String): String {
        val connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 12_000
            readTimeout = 15_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 BrokBot/1.0")
            setRequestProperty("Accept", "text/html,application/xhtml+xml,text/plain")
        }
        return try {
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code from $urlString")
            }
            body
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        private val ddgAnchorRegex = Regex(
            """<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>""",
            RegexOption.IGNORE_CASE
        )
        private val ddgSnippetRegex = Regex(
            """<(?:a|div|span)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</(?:a|div|span)>""",
            RegexOption.IGNORE_CASE
        )
        private val titleRegex = Regex("""<title[^>]*>([\s\S]*?)</title>""", RegexOption.IGNORE_CASE)
        private val scriptStyleRegex = Regex(
            """<(script|style|noscript|svg)\b[^>]*>[\s\S]*?</\1>""",
            RegexOption.IGNORE_CASE
        )
        private val tagRegex = Regex("""<[^>]+>""")
        private val whitespaceRegex = Regex("""\s+""")

        fun parseDuckDuckGoHtml(html: String, maxResults: Int = 5): List<BrowserLink> {
            val limit = maxResults.coerceIn(1, 10)
            val anchors = ddgAnchorRegex.findAll(html).toList()
            val snippets = ddgSnippetRegex.findAll(html).toList()
            val results = mutableListOf<BrowserLink>()
            val seen = mutableSetOf<String>()

            anchors.forEachIndexed { idx, match ->
                if (results.size >= limit) return@forEachIndexed
                val rawHref = decodeHtmlEntities(match.groupValues[1])
                val resolvedUrl = unwrapDuckDuckGoRedirect(rawHref)
                if (!BrowserCommandParser.isSafeHttpUrl(resolvedUrl) || !seen.add(resolvedUrl)) {
                    return@forEachIndexed
                }
                val title = cleanText(match.groupValues[2])
                if (title.isEmpty()) return@forEachIndexed
                val snippet = snippets.getOrNull(idx)?.let { cleanText(it.groupValues[1]) }.orEmpty()
                results.add(BrowserLink(title = title, url = resolvedUrl, snippet = snippet))
            }
            return results
        }

        fun parseHtmlPage(url: String, html: String, maxChars: Int = 3000): BrowserPageContext {
            val clamped = maxChars.coerceIn(200, 12_000)
            val title = titleRegex.find(html)
                ?.groupValues?.getOrNull(1)
                ?.let { cleanText(it) }
                ?.takeIf { it.isNotEmpty() }
                ?: runCatching { URI(url).host }.getOrNull()
                ?: url

            val withoutScripts = scriptStyleRegex.replace(html, " ")
            val text = cleanText(withoutScripts)
            val excerpt = if (text.length > clamped) text.take(clamped) + "…" else text
            return BrowserPageContext(url = url, title = title, excerpt = excerpt)
        }

        private fun unwrapDuckDuckGoRedirect(href: String): String {
            val normalized = if (href.startsWith("//")) "https:$href" else href
            val query = runCatching { URI(normalized).rawQuery }.getOrNull() ?: return normalized
            val uddgPair = query.split("&").firstOrNull { it.startsWith("uddg=") } ?: return normalized
            val encodedValue = uddgPair.removePrefix("uddg=")
            return runCatching { URLDecoder.decode(encodedValue, "UTF-8") }.getOrDefault(normalized)
        }

        private fun cleanText(raw: String): String {
            val noTags = tagRegex.replace(raw, " ")
            val decoded = decodeHtmlEntities(noTags)
            return whitespaceRegex.replace(decoded, " ").trim()
        }

        private fun decodeHtmlEntities(input: String): String = input
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
            .replace("&nbsp;", " ")
    }
}
