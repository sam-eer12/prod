package org.brokbot.android.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import dev.chrisbanes.haze.HazeState
import org.brokbot.android.core.browser.BrowserCommandParser
import org.brokbot.android.core.browser.BrowserPageContext
import org.brokbot.android.ui.components.LiquidGlassSurface
import org.brokbot.android.ui.theme.BrokColors
import org.json.JSONObject
import org.json.JSONTokener

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun InAppBrowserOverlay(
    hazeState: HazeState,
    initialUrl: String,
    onUrlChanged: (String) -> Unit,
    onSendPageToBot: (BrowserPageContext) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    var currentUrl by remember { mutableStateOf(BrowserCommandParser.normalizeUrlOrSearch(initialUrl)) }
    var addressInput by remember { mutableStateOf(currentUrl) }
    var pageTitle by remember { mutableStateOf("In-App Browser") }
    var progress by remember { mutableIntStateOf(0) }
    var canGoBack by remember { mutableStateOf(false) }
    var canGoForward by remember { mutableStateOf(false) }

    val webView = remember {
        WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.setSupportZoom(true)
            settings.builtInZoomControls = true
            settings.displayZoomControls = false

            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                    val target = request?.url?.toString().orEmpty()
                    return !BrowserCommandParser.isSafeHttpUrl(target)
                }

                override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                    if (url != null) {
                        currentUrl = url
                        addressInput = url
                        onUrlChanged(url)
                    }
                    canGoBack = view?.canGoBack() == true
                    canGoForward = view?.canGoForward() == true
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    if (url != null) {
                        currentUrl = url
                        addressInput = url
                        onUrlChanged(url)
                    }
                    view?.title?.takeIf { it.isNotBlank() }?.let { pageTitle = it }
                    canGoBack = view?.canGoBack() == true
                    canGoForward = view?.canGoForward() == true
                    progress = 100
                }
            }

            webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView?, newProgress: Int) {
                    progress = newProgress
                }

                override fun onReceivedTitle(view: WebView?, title: String?) {
                    if (!title.isNullOrBlank()) {
                        pageTitle = title
                    }
                }
            }
        }
    }

    LaunchedEffect(initialUrl) {
        val target = BrowserCommandParser.normalizeUrlOrSearch(initialUrl)
        if (BrowserCommandParser.isSafeHttpUrl(target) && webView.url != target) {
            currentUrl = target
            addressInput = target
            webView.loadUrl(target)
        }
    }

    DisposableEffect(webView) {
        onDispose {
            webView.stopLoading()
            webView.destroy()
        }
    }

    val navigateFromAddressBar: () -> Unit = {
        val normalized = BrowserCommandParser.normalizeUrlOrSearch(addressInput)
        if (BrowserCommandParser.isSafeHttpUrl(normalized)) {
            currentUrl = normalized
            addressInput = normalized
            webView.loadUrl(normalized)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.65f))
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(10.dp)
    ) {
        LiquidGlassSurface(
            hazeState = hazeState,
            shape = RoundedCornerShape(24.dp),
            glowColor = BrokColors.CyanAccent,
            fillAlpha = 0.85f,
            modifier = Modifier.fillMaxSize()
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                // Header & Address Bar
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = pageTitle,
                                style = MaterialTheme.typography.titleMedium,
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = currentUrl,
                                style = MaterialTheme.typography.labelMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }

                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(BrokColors.CyanAccent.copy(alpha = 0.20f))
                                    .border(1.dp, BrokColors.CyanAccent.copy(alpha = 0.50f), RoundedCornerShape(14.dp))
                                    .clickable {
                                        val script = """
                                            (function() {
                                                var title = document.title || '';
                                                var bodyText = document.body ? document.body.innerText : '';
                                                return JSON.stringify({title: title, text: bodyText.slice(0, 3500)});
                                            })();
                                        """.trimIndent()
                                        webView.evaluateJavascript(script) { raw ->
                                            val parsed = parseEvaluatedDomJson(raw)
                                            onSendPageToBot(
                                                BrowserPageContext(
                                                    url = currentUrl,
                                                    title = parsed?.first?.takeIf { it.isNotBlank() } ?: pageTitle,
                                                    excerpt = parsed?.second.orEmpty()
                                                )
                                            )
                                        }
                                    }
                                    .padding(horizontal = 10.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Check,
                                    contentDescription = "Use Page in Bot",
                                    tint = BrokColors.CyanAccent,
                                    modifier = Modifier.size(14.dp)
                                )
                                Text(
                                    text = "Send to Bot",
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = BrokColors.TextPrimary
                                )
                            }

                            IconButton(
                                onClick = {
                                    if (BrowserCommandParser.isSafeHttpUrl(currentUrl)) {
                                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(currentUrl))
                                        runCatching { context.startActivity(intent) }
                                    }
                                }
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Share,
                                    contentDescription = "Open in System Browser",
                                    tint = BrokColors.TextPrimary,
                                    modifier = Modifier.size(18.dp)
                                )
                            }

                            IconButton(onClick = onDismiss) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Close Browser",
                                    tint = BrokColors.TextPrimary
                                )
                            }
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        IconButton(onClick = { if (webView.canGoBack()) webView.goBack() }, enabled = canGoBack) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                contentDescription = "Back",
                                tint = if (canGoBack) BrokColors.TextPrimary else BrokColors.TextSecondary.copy(alpha = 0.4f),
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        IconButton(onClick = { if (webView.canGoForward()) webView.goForward() }, enabled = canGoForward) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.ArrowForward,
                                contentDescription = "Forward",
                                tint = if (canGoForward) BrokColors.TextPrimary else BrokColors.TextSecondary.copy(alpha = 0.4f),
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        IconButton(onClick = { webView.reload() }) {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = "Reload",
                                tint = BrokColors.TextPrimary,
                                modifier = Modifier.size(18.dp)
                            )
                        }

                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(14.dp))
                                .background(BrokColors.ObsidianVoid.copy(alpha = 0.60f))
                                .border(1.dp, BrokColors.BorderDim, RoundedCornerShape(14.dp))
                                .padding(horizontal = 12.dp, vertical = 8.dp)
                        ) {
                            BasicTextField(
                                value = addressInput,
                                onValueChange = { addressInput = it },
                                singleLine = true,
                                textStyle = MaterialTheme.typography.bodyMedium.copy(
                                    color = BrokColors.TextPrimary,
                                    fontSize = 12.5.sp
                                ),
                                cursorBrush = SolidColor(BrokColors.CyanAccent),
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                                keyboardActions = KeyboardActions(onGo = { navigateFromAddressBar() }),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }
                }

                if (progress in 1..99) {
                    LinearProgressIndicator(
                        progress = { progress / 100f },
                        color = BrokColors.CyanAccent,
                        trackColor = Color.Transparent,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(2.dp)
                    )
                }

                AndroidView(
                    factory = { webView },
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                )
            }
        }
    }
}

private fun parseEvaluatedDomJson(raw: String?): Pair<String, String>? {
    if (raw.isNullOrBlank() || raw == "null") return null
    return runCatching {
        val value = JSONTokener(raw).nextValue()
        val jsonStr = value as? String ?: raw
        val obj = JSONObject(jsonStr)
        val title = obj.optString("title", "")
        val text = obj.optString("text", "")
        title to text
    }.getOrNull()
}
