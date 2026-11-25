package org.brokbot.android.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.brokbot.android.R
import org.brokbot.android.core.auth.BrokAuthManager
import org.brokbot.android.core.auth.BrokAuthState
import org.brokbot.android.core.bots.BotPersona
import org.brokbot.android.core.bots.BotPersonaStore
import org.brokbot.android.core.browser.BrokBrowserEngine
import org.brokbot.android.core.browser.BrowserCommand
import org.brokbot.android.core.browser.BrowserCommandParser
import org.brokbot.android.core.browser.BrowserLink
import org.brokbot.android.core.browser.BrowserPageContext
import org.brokbot.android.core.compute.BrokComputeEngine
import org.brokbot.android.core.compute.ComputeSettings
import org.brokbot.android.core.compute.ThreadAllocation
import org.brokbot.android.core.context.MemoryEntry
import org.brokbot.android.core.context.PermanentMemoryManager
import org.brokbot.android.core.context.TurnRole
import org.brokbot.android.core.context.WorkingContextStore
import org.brokbot.android.core.context.WorkingTurn
import org.brokbot.android.core.notifications.AttentionDecision
import org.brokbot.android.core.notifications.BotAttentionCoordinator
import org.brokbot.android.core.notifications.PendingAttentionRecord
import org.brokbot.android.core.providers.BYOKProvider
import org.brokbot.android.core.providers.BYOKProviderConfig
import org.brokbot.android.ui.components.LiquidGlassSurface
import org.brokbot.android.ui.theme.BrokColors

@Composable
fun BrokHomeScreen(
    workingContextStore: WorkingContextStore,
    permanentMemoryManager: PermanentMemoryManager,
    computeEngine: BrokComputeEngine,
    byokConfigFlow: MutableStateFlow<BYOKProviderConfig>,
    authManager: BrokAuthManager? = null,
    browserEngine: BrokBrowserEngine = remember { BrokBrowserEngine() },
    botPersonaStore: BotPersonaStore = remember { BotPersonaStore() },
    attentionCoordinator: BotAttentionCoordinator = remember { BotAttentionCoordinator() },
    onResolveAttention: (String, AttentionDecision) -> Unit = { reqId, decision ->
        attentionCoordinator.resolve(reqId, decision)
    },
    onTriggerAttentionSample: (Boolean) -> Unit = {}
) {
    val hazeState = remember { HazeState() }
    val workingTurns by workingContextStore.turnsFlow.collectAsState()
    val permanentMemories by permanentMemoryManager.entriesFlow.collectAsState()
    val computeSettings by computeEngine.settingsFlow.collectAsState()
    val byokConfig by byokConfigFlow.collectAsState()
    val authState by (authManager?.authStateFlow ?: remember { MutableStateFlow(BrokAuthState()) }).collectAsState()
    val personas by botPersonaStore.personasFlow.collectAsState()
    val selectedPersona by botPersonaStore.selectedPersonaFlow.collectAsState()
    val pendingRequests by attentionCoordinator.pendingFlow.collectAsState()
    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() }
    val coroutineScope = rememberCoroutineScope()

    var composerText by remember { mutableStateOf("") }
    var showSettings by remember { mutableStateOf(false) }
    var isBrowserOpen by remember { mutableStateOf(false) }
    var browserUrl by remember { mutableStateOf("https://duckduckgo.com") }
    var activePageContext by remember { mutableStateOf<BrowserPageContext?>(null) }
    var showBotEditor by remember { mutableStateOf(false) }
    var editingBot by remember { mutableStateOf<BotPersona?>(null) }
    var lastCompactionNotice by remember { mutableStateOf<String?>(null) }

    val openInAppBrowser: (String) -> Unit = { targetUrl ->
        val normalized = BrowserCommandParser.normalizeUrlOrSearch(targetUrl)
        if (BrowserCommandParser.isSafeHttpUrl(normalized)) {
            browserUrl = normalized
            isBrowserOpen = true
        }
    }

    val listState = rememberLazyListState()

    LaunchedEffect(Unit) {
        if (workingContextStore.turns().isEmpty()) {
            workingContextStore.append(
                role = TurnRole.ASSISTANT,
                content = "Chief of Staff online. Working Context is ephemeral; Permanent Memory stays shielded locally. Try \"Store this in your memory: Prefer aisle seats\"."
            )
        }
    }

    LaunchedEffect(workingTurns.size) {
        if (workingTurns.isNotEmpty()) {
            listState.animateScrollToItem(workingTurns.lastIndex)
        }
    }

    val submitMessage: () -> Unit = {
        val trimmed = composerText.trim()
        if (trimmed.isNotEmpty()) {
            composerText = ""
            workingContextStore.append(TurnRole.USER, trimmed)
            val mutation = permanentMemoryManager.executeNaturalLanguage(trimmed)
            if (mutation != null) {
                workingContextStore.append(
                    role = TurnRole.ASSISTANT,
                    content = "${mutation.summary}\nActive enclave records: ${permanentMemoryManager.entries().size}."
                )
            } else {
                when (val browserCommand = BrowserCommandParser.parse(trimmed)) {
                    is BrowserCommand.OpenUrl -> {
                        openInAppBrowser(browserCommand.url)
                        workingContextStore.append(
                            role = TurnRole.ASSISTANT,
                            content = "Opened ${browserCommand.url} in the in-app browser.",
                            links = listOf(BrowserLink(title = "Open in In-App Browser", url = browserCommand.url))
                        )
                        coroutineScope.launch {
                            runCatching { browserEngine.fetchPage(browserCommand.url) }
                                .onSuccess { page ->
                                    activePageContext = page
                                    val preview = page.excerpt.take(260)
                                    workingContextStore.append(
                                        role = TurnRole.TOOL,
                                        content = "Loaded page \"${page.title}\":\n$preview",
                                        links = listOf(BrowserLink(title = page.title, url = page.url))
                                    )
                                }
                        }
                    }

                    is BrowserCommand.Search -> {
                        workingContextStore.append(
                            role = TurnRole.TOOL,
                            content = "Searching the web for \"${browserCommand.query}\"…"
                        )
                        coroutineScope.launch {
                            runCatching { browserEngine.searchWeb(browserCommand.query) }
                                .onSuccess { results ->
                                    if (results.isEmpty()) {
                                        val fallbackUrl = BrowserCommandParser.normalizeUrlOrSearch(browserCommand.query)
                                        openInAppBrowser(fallbackUrl)
                                        workingContextStore.append(
                                            role = TurnRole.ASSISTANT,
                                            content = "Opened DuckDuckGo search for \"${browserCommand.query}\" in the in-app browser.",
                                            links = listOf(BrowserLink(title = "Search \"${browserCommand.query}\"", url = fallbackUrl))
                                        )
                                    } else {
                                        if (browserCommand.autoOpenFirst) {
                                            openInAppBrowser(results.first().url)
                                        }
                                        val summary = results.take(5).mapIndexed { idx, item ->
                                            "${idx + 1}. ${item.title}\n   ${item.url}"
                                        }.joinToString("\n")
                                        workingContextStore.append(
                                            role = TurnRole.ASSISTANT,
                                            content = "Web results for \"${browserCommand.query}\" (tap any link to open in the in-app browser):\n\n$summary",
                                            links = results.take(5)
                                        )
                                    }
                                }
                                .onFailure {
                                    val fallbackUrl = BrowserCommandParser.normalizeUrlOrSearch(browserCommand.query)
                                    openInAppBrowser(fallbackUrl)
                                    workingContextStore.append(
                                        role = TurnRole.ASSISTANT,
                                        content = "Opened search in the in-app browser: $fallbackUrl",
                                        links = listOf(BrowserLink(title = "Open Search", url = fallbackUrl))
                                    )
                                }
                        }
                    }

                    is BrowserCommand.ReadCurrentPage -> {
                        val page = activePageContext
                        if (page != null) {
                            workingContextStore.append(
                                role = TurnRole.ASSISTANT,
                                content = "Current browser page: ${page.title} (${page.url})\n\n${page.excerpt}",
                                links = listOf(BrowserLink(title = page.title, url = page.url))
                            )
                        } else {
                            isBrowserOpen = true
                            workingContextStore.append(
                                role = TurnRole.ASSISTANT,
                                content = "Opened the in-app browser. Navigate to a page and tap \"Send to Bot\" to share its content."
                            )
                        }
                    }

                    null -> {
                        val activeThreads = computeEngine.resolveThreadCount()
                        val accel = computeEngine.effectiveAcceleratorLabel()
                        val pageHint = activePageContext?.let { "\nActive browser page: ${it.title} (${it.url})." }.orEmpty()
                        val botInstructionPreview = selectedPersona.instructions.take(140)
                        workingContextStore.append(
                            role = TurnRole.ASSISTANT,
                            content = "[${selectedPersona.name}] Routed via ${byokConfig.selectedProvider.displayName} (${byokConfig.selectedModel}) • $activeThreads thread(s) • $accel.\n" +
                                "Instructions: \"$botInstructionPreview\"\n" +
                                "Injected ${permanentMemoryManager.entries().size} permanent memory block(s) into context.$pageHint"
                        )
                    }
                }
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BrokColors.ObsidianVoid)
    ) {
        // Ambient backdrop captured by Haze for Liquid Glass refraction.
        AmbientLiquidBackdrop(
            modifier = Modifier
                .fillMaxSize()
                .hazeSource(state = hazeState)
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            ChiefOfStaffHeader(
                hazeState = hazeState,
                selectedPersona = selectedPersona,
                providerConfig = byokConfig,
                computeEngine = computeEngine,
                computeSettings = computeSettings,
                permanentCount = permanentMemories.size,
                authState = authState,
                hasActiveBrowserPage = activePageContext != null,
                onEditBot = {
                    editingBot = selectedPersona
                    showBotEditor = true
                },
                onOpenBrowser = { isBrowserOpen = true },
                onOpenSettings = { showSettings = true }
            )

            TeammatesStrip(
                personas = personas,
                selectedPersona = selectedPersona,
                onSelectBot = { botPersonaStore.selectBot(it.id) },
                onNewBot = {
                    editingBot = null
                    showBotEditor = true
                }
            )

            DualSpaceSummaryStrip(
                hazeState = hazeState,
                workingTurnCount = workingTurns.size,
                workingTokenEstimate = workingContextStore.totalTokens(),
                permanentCount = permanentMemories.size,
                onClearWorking = {
                    workingContextStore.clear()
                    workingContextStore.append(
                        TurnRole.SYSTEM,
                        "Working Context cleared. ${permanentMemoryManager.entries().size} Permanent Memory record(s) preserved."
                    )
                },
                onOpenInspector = { showSettings = true }
            )

            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentPadding = PaddingValues(vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(workingTurns, key = { it.id }) { turn ->
                    WorkingTurnCard(
                        hazeState = hazeState,
                        turn = turn,
                        onOpenLink = openInAppBrowser
                    )
                }
            }

            if (pendingRequests.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    pendingRequests.forEach { pending ->
                        PendingApprovalCard(
                            hazeState = hazeState,
                            record = pending,
                            onAllowOnce = { onResolveAttention(pending.requestId, AttentionDecision.ALLOW_ONCE) },
                            onDeny = { onResolveAttention(pending.requestId, AttentionDecision.DENY) }
                        )
                    }
                }
            }

            MemoryQuickCommandsRow(
                onInsertTemplate = { template -> composerText = template }
            )

            DualSpaceComposer(
                hazeState = hazeState,
                value = composerText,
                onValueChange = { composerText = it },
                onSend = submitMessage
            )
        }

        AnimatedVisibility(
            visible = isBrowserOpen,
            enter = fadeIn() + slideInVertically { it / 4 },
            exit = fadeOut() + slideOutVertically { it / 4 }
        ) {
            InAppBrowserOverlay(
                hazeState = hazeState,
                initialUrl = browserUrl,
                onUrlChanged = { browserUrl = it },
                onSendPageToBot = { page ->
                    activePageContext = page
                    isBrowserOpen = false
                    workingContextStore.append(
                        role = TurnRole.TOOL,
                        content = "Captured from in-app browser: ${page.title} (${page.url})\n\n${page.excerpt.take(1200)}",
                        links = listOf(BrowserLink(title = page.title, url = page.url))
                    )
                },
                onDismiss = { isBrowserOpen = false }
            )
        }

        AnimatedVisibility(
            visible = showBotEditor,
            enter = fadeIn() + slideInVertically { it / 3 },
            exit = fadeOut() + slideOutVertically { it / 3 }
        ) {
            BotEditorOverlay(
                hazeState = hazeState,
                existingPersona = editingBot,
                onSave = { saved ->
                    if (editingBot == null) {
                        botPersonaStore.createBot(saved)
                    } else {
                        botPersonaStore.updateBot(saved)
                    }
                    showBotEditor = false
                },
                onDismiss = { showBotEditor = false }
            )
        }

        AnimatedVisibility(
            visible = showSettings,
            enter = fadeIn() + slideInVertically { it / 3 },
            exit = fadeOut() + slideOutVertically { it / 3 }
        ) {
            SettingsModalOverlay(
                hazeState = hazeState,
                computeSettings = computeSettings,
                computeEngine = computeEngine,
                permanentMemories = permanentMemories,
                byokConfig = byokConfig,
                authState = authState,
                compactionNotice = lastCompactionNotice,
                onSignInWithGoogle = {
                    val hostActivity = activity ?: return@SettingsModalOverlay
                    coroutineScope.launch {
                        authManager?.signInWithGoogle(hostActivity)
                    }
                },
                onSignInWithApple = {
                    val hostActivity = activity ?: return@SettingsModalOverlay
                    coroutineScope.launch {
                        authManager?.signInWithApple(hostActivity)
                    }
                },
                onSignOut = {
                    coroutineScope.launch {
                        authManager?.signOut(context)
                    }
                },
                onSelectThreads = { computeEngine.setThreadAllocation(it) },
                onToggleNnapi = { computeEngine.setNnapiVulkanEnabled(it) },
                onSelectProvider = { provider ->
                    byokConfigFlow.value = byokConfig.copy(
                        selectedProvider = provider,
                        selectedModel = provider.defaultModel
                    )
                },
                onCompactMemories = {
                    val report = permanentMemoryManager.compact()
                    lastCompactionNotice =
                        "Compacted ${report.beforeCount} -> ${report.afterCount} record(s) (${report.removedCount} merged)."
                },
                onDeleteMemory = { id -> permanentMemoryManager.removeById(id) },
                onTriggerAttentionSample = onTriggerAttentionSample,
                onDismiss = { showSettings = false }
            )
        }
    }
}

@Composable
private fun AmbientLiquidBackdrop(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        drawRect(color = BrokColors.ObsidianVoid)
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(
                    BrokColors.CyanAccent.copy(alpha = 0.18f),
                    Color.Transparent
                ),
                center = Offset(size.width * 0.18f, size.height * 0.14f),
                radius = size.width * 0.72f
            ),
            radius = size.width * 0.72f,
            center = Offset(size.width * 0.18f, size.height * 0.14f)
        )
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(
                    BrokColors.MonocleGold.copy(alpha = 0.15f),
                    Color.Transparent
                ),
                center = Offset(size.width * 0.86f, size.height * 0.72f),
                radius = size.width * 0.68f
            ),
            radius = size.width * 0.68f,
            center = Offset(size.width * 0.86f, size.height * 0.72f)
        )
    }
}

@Composable
private fun ChiefOfStaffHeader(
    hazeState: HazeState,
    selectedPersona: BotPersona,
    providerConfig: BYOKProviderConfig,
    computeEngine: BrokComputeEngine,
    computeSettings: ComputeSettings,
    permanentCount: Int,
    authState: BrokAuthState,
    hasActiveBrowserPage: Boolean,
    onEditBot: () -> Unit,
    onOpenBrowser: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val activeThreads = computeEngine.resolveThreadCount(computeSettings.threadAllocation)
    val accelTag = if (computeSettings.nnapiVulkanEnabled) "NNAPI" else "CPU"
    val accountTag = authState.user?.let { it.displayName ?: it.email ?: it.providerLabel } ?: "Sign In"
    val botGlow = parseHexColor(selectedPersona.accentHex)

    LiquidGlassSurface(
        hazeState = hazeState,
        glowColor = botGlow,
        shape = RoundedCornerShape(24.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            BotAvatarView(
                persona = selectedPersona,
                size = 44.dp
            )
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = selectedPersona.name,
                    style = MaterialTheme.typography.titleLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = "${selectedPersona.role} • ${providerConfig.selectedProvider.displayName} • ${activeThreads}T $accelTag • $accountTag",
                    style = MaterialTheme.typography.labelMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            IconButton(onClick = onEditBot) {
                Icon(
                    imageVector = Icons.Rounded.Edit,
                    contentDescription = "Edit Bot",
                    tint = BrokColors.TextPrimary,
                    modifier = Modifier.size(19.dp)
                )
            }
            IconButton(onClick = onOpenBrowser) {
                Icon(
                    imageVector = Icons.Rounded.Search,
                    contentDescription = "In-App Browser",
                    tint = if (hasActiveBrowserPage) BrokColors.CyanAccent else BrokColors.TextPrimary
                )
            }
            IconButton(onClick = onOpenSettings) {
                Icon(
                    imageVector = Icons.Rounded.Settings,
                    contentDescription = "Settings",
                    tint = BrokColors.TextPrimary
                )
            }
        }
    }
}

@Composable
private fun TeammatesStrip(
    personas: List<BotPersona>,
    selectedPersona: BotPersona,
    onSelectBot: (BotPersona) -> Unit,
    onNewBot: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        personas.forEach { persona ->
            val isSelected = persona.id == selectedPersona.id
            val botColor = parseHexColor(persona.accentHex)
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(16.dp))
                    .background(
                        if (isSelected) botColor.copy(alpha = 0.18f)
                        else BrokColors.GlassTint.copy(alpha = 0.55f)
                    )
                    .border(
                        width = 1.dp,
                        color = if (isSelected) botColor.copy(alpha = 0.70f) else BrokColors.BorderDim,
                        shape = RoundedCornerShape(16.dp)
                    )
                    .clickable { onSelectBot(persona) }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp)
            ) {
                BotAvatarView(persona = persona, size = 22.dp)
                Text(
                    text = persona.name,
                    fontSize = 12.sp,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (isSelected) BrokColors.TextPrimary else BrokColors.TextSecondary,
                    maxLines = 1
                )
            }
        }

        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(BrokColors.CyanAccent.copy(alpha = 0.14f))
                .border(1.dp, BrokColors.CyanAccent.copy(alpha = 0.45f), RoundedCornerShape(16.dp))
                .clickable(onClick = onNewBot)
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(
                imageVector = Icons.Rounded.Add,
                contentDescription = "New Bot",
                tint = BrokColors.CyanAccent,
                modifier = Modifier.size(15.dp)
            )
            Text(
                text = "New Bot",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = BrokColors.CyanAccent
            )
        }
    }
}

@Composable
private fun PendingApprovalCard(
    hazeState: HazeState,
    record: PendingAttentionRecord,
    onAllowOnce: () -> Unit,
    onDeny: () -> Unit
) {
    LiquidGlassSurface(
        hazeState = hazeState,
        glowColor = BrokColors.MonocleGold,
        shape = RoundedCornerShape(18.dp),
        fillAlpha = 0.62f,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = "${record.botName} • Needs Attention",
                fontSize = 11.5.sp,
                fontWeight = FontWeight.SemiBold,
                color = BrokColors.MonocleGoldSoft
            )
            Text(
                text = record.actionSummary,
                style = MaterialTheme.typography.bodyMedium
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.Red.copy(alpha = 0.16f))
                        .border(1.dp, Color.Red.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
                        .clickable(onClick = onDeny)
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("Deny", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFFFF8A80))
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(12.dp))
                        .background(BrokColors.EmeraldOk.copy(alpha = 0.20f))
                        .border(1.dp, BrokColors.EmeraldOk.copy(alpha = 0.55f), RoundedCornerShape(12.dp))
                        .clickable(onClick = onAllowOnce)
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("Allow once", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.EmeraldOk)
                }
            }
        }
    }
}

@Composable
private fun DualSpaceSummaryStrip(
    hazeState: HazeState,
    workingTurnCount: Int,
    workingTokenEstimate: Int,
    permanentCount: Int,
    onClearWorking: () -> Unit,
    onOpenInspector: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        LiquidGlassSurface(
            hazeState = hazeState,
            shape = RoundedCornerShape(16.dp),
            glowColor = BrokColors.CyanAccent,
            modifier = Modifier.weight(1f)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Working Space",
                        fontSize = 11.sp,
                        color = BrokColors.CyanAccent,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = "$workingTurnCount turns • ~$workingTokenEstimate tok",
                        fontSize = 12.sp,
                        color = BrokColors.TextSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text(
                    text = "Reset",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = BrokColors.TextPrimary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(onClick = onClearWorking)
                        .padding(horizontal = 6.dp, vertical = 4.dp)
                )
            }
        }

        LiquidGlassSurface(
            hazeState = hazeState,
            shape = RoundedCornerShape(16.dp),
            glowColor = BrokColors.MonocleGold,
            modifier = Modifier
                .weight(1f)
                .clickable(onClick = onOpenInspector)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Permanent Enclave",
                        fontSize = 11.sp,
                        color = BrokColors.MonocleGoldSoft,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = "$permanentCount encrypted facts",
                        fontSize = 12.sp,
                        color = BrokColors.TextSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Icon(
                    imageVector = Icons.Rounded.Lock,
                    contentDescription = "Inspect Permanent Memory",
                    tint = BrokColors.MonocleGoldSoft,
                    modifier = Modifier.size(16.dp)
                )
            }
        }
    }
}

@Composable
private fun WorkingTurnCard(
    hazeState: HazeState,
    turn: WorkingTurn,
    onOpenLink: (String) -> Unit
) {
    val isUser = turn.role == TurnRole.USER
    val accent = when (turn.role) {
        TurnRole.USER -> BrokColors.CyanAccent
        TurnRole.ASSISTANT -> BrokColors.MonocleGold
        TurnRole.SYSTEM -> BrokColors.EmeraldOk
        TurnRole.TOOL -> BrokColors.TextSecondary
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
    ) {
        LiquidGlassSurface(
            hazeState = hazeState,
            glowColor = accent,
            shape = RoundedCornerShape(18.dp),
            fillAlpha = if (isUser) 0.50f else 0.36f,
            modifier = Modifier.fillMaxWidth(0.92f)
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = turn.role.label,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = accent
                )
                Text(
                    text = turn.content,
                    style = MaterialTheme.typography.bodyMedium
                )
                if (turn.links.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        turn.links.forEach { link ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(BrokColors.CyanAccent.copy(alpha = 0.14f))
                                    .border(1.dp, BrokColors.CyanAccent.copy(alpha = 0.40f), RoundedCornerShape(12.dp))
                                    .clickable { onOpenLink(link.url) }
                                    .padding(horizontal = 10.dp, vertical = 7.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = link.title,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = BrokColors.TextPrimary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        text = link.url,
                                        fontSize = 10.5.sp,
                                        color = BrokColors.CyanAccent,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                                Text(
                                    text = "Open",
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = BrokColors.CyanAccent,
                                    modifier = Modifier.padding(start = 8.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MemoryQuickCommandsRow(onInsertTemplate: (String) -> Unit) {
    val templates = listOf(
        "Search Web" to "Search for ",
        "Open URL" to "Open https://",
        "Store Memory" to "Store this in your memory: ",
        "Update Memory" to "Update my memory about ",
        "Forget Memory" to "Forget "
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        templates.forEach { (label, prefix) ->
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(14.dp))
                    .background(BrokColors.GlassTint.copy(alpha = 0.62f))
                    .border(1.dp, BrokColors.BorderDim, RoundedCornerShape(14.dp))
                    .clickable { onInsertTemplate(prefix) }
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            ) {
                Text(
                    text = label,
                    fontSize = 12.sp,
                    color = BrokColors.TextSecondary
                )
            }
        }
    }
}

@Composable
private fun DualSpaceComposer(
    hazeState: HazeState,
    value: String,
    onValueChange: (String) -> Unit,
    onSend: () -> Unit
) {
    LiquidGlassSurface(
        hazeState = hazeState,
        shape = RoundedCornerShape(26.dp),
        glowColor = BrokColors.CyanAccent,
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(modifier = Modifier.weight(1f)) {
                if (value.isEmpty()) {
                    Text(
                        text = "Ask Chief of Staff or Store / Update / Forget memory…",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BrokColors.TextSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(color = BrokColors.TextPrimary),
                    cursorBrush = SolidColor(BrokColors.CyanAccent),
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { onSend() }),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            IconButton(
                onClick = onSend,
                enabled = value.isNotBlank()
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Rounded.Send,
                    contentDescription = "Send",
                    tint = if (value.isNotBlank()) BrokColors.CyanAccent else BrokColors.TextSecondary
                )
            }
        }
    }
}

@Composable
private fun SettingsModalOverlay(
    hazeState: HazeState,
    computeSettings: ComputeSettings,
    computeEngine: BrokComputeEngine,
    permanentMemories: List<MemoryEntry>,
    byokConfig: BYOKProviderConfig,
    authState: BrokAuthState,
    compactionNotice: String?,
    onSignInWithGoogle: () -> Unit,
    onSignInWithApple: () -> Unit,
    onSignOut: () -> Unit,
    onSelectThreads: (ThreadAllocation) -> Unit,
    onToggleNnapi: (Boolean) -> Unit,
    onSelectProvider: (BYOKProvider) -> Unit,
    onCompactMemories: () -> Unit,
    onDeleteMemory: (String) -> Unit,
    onTriggerAttentionSample: (Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    val backdropInteraction = remember { MutableInteractionSource() }
    val sheetInteraction = remember { MutableInteractionSource() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.56f))
            .clickable(
                interactionSource = backdropInteraction,
                indication = null,
                onClick = onDismiss
            )
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(16.dp),
        contentAlignment = Alignment.BottomCenter
    ) {
        LiquidGlassSurface(
            hazeState = hazeState,
            shape = RoundedCornerShape(28.dp),
            glowColor = BrokColors.MonocleGold,
            fillAlpha = 0.72f,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 680.dp)
                .clickable(
                    interactionSource = sheetInteraction,
                    indication = null,
                    onClick = {}
                )
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(18.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column {
                        Text(
                            text = "Engine & Enclave Settings",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "Compute allocation, BYOK providers & Permanent Memory",
                            style = MaterialTheme.typography.labelMedium
                        )
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "Close Settings",
                            tint = BrokColors.TextPrimary
                        )
                    }
                }

                HorizontalDivider(color = BrokColors.BorderDim)

                // 0. Firebase Account (Google & Apple Sign-In)
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(BrokColors.ObsidianVoid.copy(alpha = 0.42f))
                        .border(1.dp, BrokColors.BorderDim, RoundedCornerShape(16.dp))
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "Account (Firebase Auth)",
                            style = MaterialTheme.typography.titleMedium,
                            fontSize = 14.sp
                        )
                        Text(
                            text = authState.user?.providerLabel ?: "brokbot-auth-2026",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (authState.user != null) BrokColors.EmeraldOk else BrokColors.CyanAccent
                        )
                    }

                    val activeUser = authState.user
                    if (activeUser != null) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                text = activeUser.displayName ?: activeUser.email ?: activeUser.uid,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = BrokColors.TextPrimary
                            )
                            activeUser.email?.let { email ->
                                Text(
                                    text = email,
                                    fontSize = 11.sp,
                                    color = BrokColors.TextSecondary
                                )
                            }
                        }
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color.Red.copy(alpha = 0.16f))
                                .border(1.dp, Color.Red.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
                                .clickable(onClick = onSignOut)
                                .padding(horizontal = 12.dp, vertical = 7.dp)
                        ) {
                            Text(
                                text = "Sign Out",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = BrokColors.TextPrimary
                            )
                        }
                    } else {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(BrokColors.CyanAccent.copy(alpha = 0.18f))
                                    .border(1.dp, BrokColors.CyanAccent.copy(alpha = 0.50f), RoundedCornerShape(12.dp))
                                    .clickable(enabled = !authState.isLoading, onClick = onSignInWithGoogle)
                                    .padding(vertical = 9.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = if (authState.isLoading) "Signing in…" else "Google",
                                    fontSize = 12.5.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = BrokColors.TextPrimary
                                )
                            }
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(BrokColors.MonocleGold.copy(alpha = 0.16f))
                                    .border(1.dp, BrokColors.MonocleGold.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
                                    .clickable(enabled = !authState.isLoading, onClick = onSignInWithApple)
                                    .padding(vertical = 9.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = "Apple",
                                    fontSize = 12.5.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = BrokColors.TextPrimary
                                )
                            }
                        }
                    }

                    authState.errorMessage?.let { errorMsg ->
                        Text(
                            text = errorMsg,
                            fontSize = 11.sp,
                            color = Color(0xFFFF8A80)
                        )
                    } ?: authState.statusMessage?.let { statusMsg ->
                        Text(
                            text = statusMsg,
                            fontSize = 11.sp,
                            color = BrokColors.EmeraldOk
                        )
                    }
                }

                // 0b. Test Bot Attention & Approval Notifications
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(BrokColors.CyanAccent.copy(alpha = 0.16f))
                            .border(1.dp, BrokColors.CyanAccent.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
                            .clickable {
                                onTriggerAttentionSample(false)
                                onDismiss()
                            }
                            .padding(vertical = 9.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("Test Task Alert", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.TextPrimary)
                    }
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(BrokColors.MonocleGold.copy(alpha = 0.18f))
                            .border(1.dp, BrokColors.MonocleGold.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
                            .clickable {
                                onTriggerAttentionSample(true)
                                onDismiss()
                            }
                            .padding(vertical = 9.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("Test Approval Alert", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.TextPrimary)
                    }
                }

                // 1. Thread Count Selector (1 / 2 / 4 / Auto)
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    val resolved = computeEngine.resolveThreadCount(computeSettings.threadAllocation)
                    Text(
                        text = "Worker Thread Count (Active: $resolved)",
                        style = MaterialTheme.typography.titleMedium,
                        fontSize = 14.sp
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        ThreadAllocation.entries.forEach { allocation ->
                            val selected = computeSettings.threadAllocation == allocation
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(
                                        if (selected) BrokColors.CyanAccent.copy(alpha = 0.22f)
                                        else BrokColors.ObsidianVoid.copy(alpha = 0.45f)
                                    )
                                    .border(
                                        width = 1.dp,
                                        color = if (selected) BrokColors.CyanAccent else BrokColors.BorderDim,
                                        shape = RoundedCornerShape(14.dp)
                                    )
                                    .clickable { onSelectThreads(allocation) }
                                    .padding(vertical = 10.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = allocation.label,
                                    fontSize = 13.sp,
                                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                    color = if (selected) BrokColors.CyanAccent else BrokColors.TextPrimary
                                )
                            }
                        }
                    }
                }

                // 2. NNAPI / Vulkan Hardware Acceleration Toggle
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(BrokColors.ObsidianVoid.copy(alpha = 0.40f))
                        .border(1.dp, BrokColors.BorderDim, RoundedCornerShape(16.dp))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "NNAPI / Vulkan Acceleration",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium
                        )
                        Text(
                            text = computeEngine.effectiveAcceleratorLabel(),
                            style = MaterialTheme.typography.labelMedium
                        )
                    }
                    Switch(
                        checked = computeSettings.nnapiVulkanEnabled,
                        onCheckedChange = onToggleNnapi,
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = BrokColors.ObsidianVoid,
                            checkedTrackColor = BrokColors.CyanAccent
                        )
                    )
                }

                // 3. BYOK Provider Picker
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "BYOK Provider",
                        style = MaterialTheme.typography.titleMedium,
                        fontSize = 14.sp
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        BYOKProvider.entries.forEach { provider ->
                            val selected = byokConfig.selectedProvider == provider
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(
                                        if (selected) BrokColors.MonocleGold.copy(alpha = 0.16f)
                                        else BrokColors.ObsidianVoid.copy(alpha = 0.35f)
                                    )
                                    .border(
                                        width = 1.dp,
                                        color = if (selected) BrokColors.MonocleGold else BrokColors.BorderDim,
                                        shape = RoundedCornerShape(14.dp)
                                    )
                                    .clickable { onSelectProvider(provider) }
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = provider.displayName,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = if (selected) BrokColors.MonocleGoldSoft else BrokColors.TextPrimary
                                    )
                                    Text(
                                        text = provider.defaultModel,
                                        fontSize = 11.sp,
                                        color = BrokColors.TextSecondary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                                if (selected) {
                                    Text(
                                        text = "Active",
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = BrokColors.MonocleGoldSoft
                                    )
                                }
                            }
                        }
                    }
                }

                // 4. Permanent Memory Inspector
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "Permanent Memory (${permanentMemories.size})",
                            style = MaterialTheme.typography.titleMedium,
                            fontSize = 14.sp
                        )
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(12.dp))
                                .background(BrokColors.CyanAccent.copy(alpha = 0.14f))
                                .border(1.dp, BrokColors.CyanAccent.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                                .clickable(onClick = onCompactMemories)
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = "Compact Memory",
                                tint = BrokColors.CyanAccent,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = "Compact",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = BrokColors.CyanAccent
                            )
                        }
                    }

                    compactionNotice?.let { notice ->
                        Text(
                            text = notice,
                            fontSize = 11.sp,
                            color = BrokColors.EmeraldOk
                        )
                    }

                    if (permanentMemories.isEmpty()) {
                        Text(
                            text = "No permanent memories stored. Use \"Store this in your memory: ...\" in chat.",
                            style = MaterialTheme.typography.labelMedium
                        )
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            permanentMemories.forEach { entry ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(14.dp))
                                        .background(BrokColors.ObsidianVoid.copy(alpha = 0.42f))
                                        .border(1.dp, BrokColors.BorderDim, RoundedCornerShape(14.dp))
                                        .padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = entry.category.uppercase(),
                                            fontSize = 10.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            color = BrokColors.MonocleGoldSoft
                                        )
                                        Text(
                                            text = entry.content,
                                            fontSize = 13.sp,
                                            color = BrokColors.TextPrimary
                                        )
                                    }
                                    IconButton(onClick = { onDeleteMemory(entry.id) }) {
                                        Icon(
                                            imageVector = Icons.Rounded.Delete,
                                            contentDescription = "Delete Memory",
                                            tint = BrokColors.TextSecondary,
                                            modifier = Modifier.size(18.dp)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
