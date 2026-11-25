package org.brokbot.android

import org.brokbot.android.core.browser.BrokBrowserEngine
import org.brokbot.android.core.browser.BrowserCommand
import org.brokbot.android.core.browser.BrowserCommandParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BrokBrowserEngineTest {

    @Test
    fun `command parser detects open, search, read page, and normal chat`() {
        assertEquals(
            BrowserCommand.OpenUrl("https://brokbot.dev"),
            BrowserCommandParser.parse("open brokbot.dev")
        )
        assertEquals(
            BrowserCommand.OpenUrl("https://github.com/brok-bot"),
            BrowserCommandParser.parse("visit https://github.com/brok-bot")
        )
        assertEquals(
            BrowserCommand.Search(query = "kotlin compose haze", autoOpenFirst = false),
            BrowserCommandParser.parse("search for kotlin compose haze")
        )
        assertEquals(
            BrowserCommand.Search(query = "openai api docs", autoOpenFirst = true),
            BrowserCommandParser.parse("search and open openai api docs")
        )
        assertEquals(
            BrowserCommand.ReadCurrentPage,
            BrowserCommandParser.parse("summarize this page")
        )
        assertNull(BrowserCommandParser.parse("What is on my schedule tomorrow?"))
    }

    @Test
    fun `url safety and normalization restrict non-http schemes`() {
        assertTrue(BrowserCommandParser.isSafeHttpUrl("https://example.com/path"))
        assertTrue(BrowserCommandParser.isSafeHttpUrl("http://localhost:8080"))
        assertFalse(BrowserCommandParser.isSafeHttpUrl("file:///sdcard/secret.txt"))
        assertFalse(BrowserCommandParser.isSafeHttpUrl("javascript:alert(1)"))

        assertEquals("https://developer.android.com", BrowserCommandParser.normalizeUrlOrSearch("developer.android.com"))
        assertTrue(BrowserCommandParser.normalizeUrlOrSearch("latest compose bom").startsWith("https://duckduckgo.com/?q="))
    }

    @Test
    fun `duckduckgo and page parsers extract clean results and text`() {
        val ddgHtml = """
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fkotlinlang.org%2F&amp;rut=abc">Kotlin &amp; Multiplatform</a>
            <span class="result__snippet">Official Kotlin documentation.</span>
        """.trimIndent()
        val links = BrokBrowserEngine.parseDuckDuckGoHtml(ddgHtml, maxResults = 5)
        assertEquals(1, links.size)
        assertEquals("Kotlin & Multiplatform", links[0].title)
        assertEquals("https://kotlinlang.org/", links[0].url)
        assertEquals("Official Kotlin documentation.", links[0].snippet)

        val pageHtml = """
            <html>
              <head><title>Brok Android</title><style>body{color:red;}</style></head>
              <body><h1>Welcome</h1><p>In-app browser ready.</p></body>
            </html>
        """.trimIndent()
        val page = BrokBrowserEngine.parseHtmlPage("https://brokbot.dev", pageHtml, maxChars = 500)
        assertEquals("Brok Android", page.title)
        assertTrue(page.excerpt.contains("In-app browser ready."))
        assertFalse(page.excerpt.contains("color:red"))
    }
}
