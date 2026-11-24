package org.brokbot.android.ui

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
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Refresh
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
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
import org.brokbot.android.R
import org.brokbot.android.core.compute.BrokComputeEngine
import org.brokbot.android.core.compute.ComputeSettings
import org.brokbot.android.core.compute.ThreadAllocation
import org.brokbot.android.core.context.MemoryEntry
import org.brokbot.android.core.context.PermanentMemoryManager
import org.brokbot.android.core.context.TurnRole
import org.brokbot.android.core.context.WorkingContextStore
import org.brokbot.android.core.context.WorkingTurn
import org.brokbot.android.core.providers.BYOKProvider
import org.brokbot.android.core.providers.BYOKProviderConfig
import org.brokbot.android.ui.components.LiquidGlassSurface
import org.brokbot.android.ui.theme.BrokColors

@Composable
fun BrokHomeScreen(
    workingContextStore: WorkingContextStore,
    permanentMemoryManager: PermanentMemoryManager,
    computeEngine: BrokComputeEngine,
    byokConfigFlow: MutableStateFlow<BYOKProviderConfig>
) {
    val hazeState = remember { HazeState() }
    val workingTurns by workingContextStore.turnsFlow.collectAsState()
    val permanentMemories by permanentMemoryManager.entriesFlow.collectAsState()
    val computeSettings by computeEngine.settingsFlow.collectAsState()
    val byokConfig by byokConfigFlow.collectAsState()

    var composerText by remember { mutableStateOf("") }
    var showSettings by remember { mutableStateOf(false) }
    var lastCompactionNotice by remember { mutableStateOf<String?>(null) }

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
                val activeThreads = computeEngine.resolveThreadCount()
                val accel = computeEngine.effectiveAcceleratorLabel()
                workingContextStore.append(
                    role = TurnRole.ASSISTANT,
                    content = "Routed via ${byokConfig.selectedProvider.displayName} (${byokConfig.selectedModel}) • $activeThreads thread(s) • $accel.\n" +
                        "Injected ${permanentMemoryManager.entries().size} permanent memory block(s) into context. Connect your API key in Settings to stream live completions."
                )
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
                providerConfig = byokConfig,
                computeEngine = computeEngine,
                computeSettings = computeSettings,
                permanentCount = permanentMemories.size,
                onOpenSettings = { showSettings = true }
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
                    WorkingTurnCard(hazeState = hazeState, turn = turn)
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
                compactionNotice = lastCompactionNotice,
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
    providerConfig: BYOKProviderConfig,
    computeEngine: BrokComputeEngine,
    computeSettings: ComputeSettings,
    permanentCount: Int,
    onOpenSettings: () -> Unit
) {
    val activeThreads = computeEngine.resolveThreadCount(computeSettings.threadAllocation)
    val accelTag = if (computeSettings.nnapiVulkanEnabled) "NNAPI" else "CPU"

    LiquidGlassSurface(
        hazeState = hazeState,
        glowColor = BrokColors.MonocleGold,
        shape = RoundedCornerShape(24.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Image(
                painter = painterResource(id = R.drawable.brok_logo),
                contentDescription = stringResource(R.string.app_name),
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .border(
                        width = 1.2.dp,
                        color = BrokColors.MonocleGold.copy(alpha = 0.7f),
                        shape = CircleShape
                    )
            )
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.chief_of_staff_title),
                    style = MaterialTheme.typography.titleLarge
                )
                Text(
                    text = "${providerConfig.selectedProvider.displayName} • ${activeThreads}T $accelTag • $permanentCount Enclave",
                    style = MaterialTheme.typography.labelMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
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
    turn: WorkingTurn
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
                verticalArrangement = Arrangement.spacedBy(4.dp)
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
            }
        }
    }
}

@Composable
private fun MemoryQuickCommandsRow(onInsertTemplate: (String) -> Unit) {
    val templates = listOf(
        "Store" to "Store this in your memory: ",
        "Update" to "Update my memory about ",
        "Forget" to "Forget "
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
                    text = "$label Memory",
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
    compactionNotice: String?,
    onSelectThreads: (ThreadAllocation) -> Unit,
    onToggleNnapi: (Boolean) -> Unit,
    onSelectProvider: (BYOKProvider) -> Unit,
    onCompactMemories: () -> Unit,
    onDeleteMemory: (String) -> Unit,
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
