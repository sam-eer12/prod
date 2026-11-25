package org.brokbot.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chrisbanes.haze.HazeState
import org.brokbot.android.core.bots.BotAvatarFace
import org.brokbot.android.core.bots.BotAvatarShape
import org.brokbot.android.core.bots.BotAvatarSpec
import org.brokbot.android.core.bots.BotAvatarStyle
import org.brokbot.android.core.bots.BotPersona
import org.brokbot.android.ui.components.LiquidGlassSurface
import org.brokbot.android.ui.theme.BrokColors
import java.util.UUID

@Composable
fun BotEditorOverlay(
    hazeState: HazeState,
    existingPersona: BotPersona?,
    onSave: (BotPersona) -> Unit,
    onDismiss: () -> Unit
) {
    var selectedPresetId by remember(existingPersona?.id) { mutableStateOf<String?>(null) }
    var name by remember(existingPersona?.id) { mutableStateOf(existingPersona?.name.orEmpty()) }
    var role by remember(existingPersona?.id) { mutableStateOf(existingPersona?.role.orEmpty()) }
    var instructions by remember(existingPersona?.id) { mutableStateOf(existingPersona?.instructions.orEmpty()) }
    var accentHex by remember(existingPersona?.id) { mutableStateOf(existingPersona?.accentHex ?: "#00E5FF") }
    var shape by remember(existingPersona?.id) { mutableStateOf(existingPersona?.avatar?.shape ?: BotAvatarShape.CIRCLE) }
    var style by remember(existingPersona?.id) { mutableStateOf(existingPersona?.avatar?.style ?: BotAvatarStyle.FACE) }
    var face by remember(existingPersona?.id) { mutableStateOf(existingPersona?.avatar?.face ?: BotAvatarFace.DOTS) }
    var iconKey by remember(existingPersona?.id) { mutableStateOf(existingPersona?.iconKey ?: "sparkles") }
    var notificationsEnabled by remember(existingPersona?.id) { mutableStateOf(existingPersona?.notificationsEnabled ?: true) }

    val colorSwatches = listOf("#00E5FF", "#FF9F0A", "#34D399", "#A78BFA", "#F472B6", "#60A5FA", "#F87171", "#FACC15")
    val iconChoices = listOf("sparkles", "cube", "tray", "code", "globe", "shield", "bolt")
    val previewColor = parseHexColor(accentHex)
    val currentAvatar = BotAvatarSpec(shape = shape, style = style, face = face)
    val canSave = name.isNotBlank() && role.isNotBlank() && instructions.isNotBlank()

    val backdropInteraction = remember { MutableInteractionSource() }
    val sheetInteraction = remember { MutableInteractionSource() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.62f))
            .clickable(interactionSource = backdropInteraction, indication = null, onClick = onDismiss)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(14.dp),
        contentAlignment = Alignment.BottomCenter
    ) {
        LiquidGlassSurface(
            hazeState = hazeState,
            shape = RoundedCornerShape(28.dp),
            glowColor = previewColor,
            fillAlpha = 0.80f,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 720.dp)
                .clickable(interactionSource = sheetInteraction, indication = null, onClick = {})
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(18.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column {
                        Text(
                            text = if (existingPersona == null) "New Bot" else "Edit Bot",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "Instructions, silhouette shape, color, face/icon & alerts",
                            style = MaterialTheme.typography.labelMedium
                        )
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "Close Bot Editor",
                            tint = BrokColors.TextPrimary
                        )
                    }
                }

                // Dual Live Preview (List 30dp + Header 44dp)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(BrokColors.ObsidianVoid.copy(alpha = 0.45f))
                        .border(1.dp, previewColor.copy(alpha = 0.40f), RoundedCornerShape(16.dp))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        BotAvatarView(
                            avatar = currentAvatar,
                            accentHex = accentHex,
                            iconKey = iconKey,
                            fallbackInitial = name.firstOrNull()?.uppercaseChar()?.toString() ?: "B",
                            size = 30.dp
                        )
                        Text("List", fontSize = 9.sp, color = BrokColors.TextSecondary)
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        BotAvatarView(
                            avatar = currentAvatar,
                            accentHex = accentHex,
                            iconKey = iconKey,
                            fallbackInitial = name.firstOrNull()?.uppercaseChar()?.toString() ?: "B",
                            size = 44.dp
                        )
                        Text("Header", fontSize = 9.sp, color = BrokColors.TextSecondary)
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = name.ifBlank { "Bot Name" },
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = BrokColors.TextPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = role.ifBlank { "Specialist Role" },
                            fontSize = 11.5.sp,
                            color = BrokColors.TextSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }

                if (existingPersona == null) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("Starting Point", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.TextSecondary)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            PresetChip(
                                label = "Blank Bot",
                                selected = selectedPresetId == null,
                                accent = previewColor
                            ) {
                                selectedPresetId = null
                                name = ""
                                role = ""
                                instructions = ""
                            }
                            BotPersona.presets.forEach { preset ->
                                PresetChip(
                                    label = preset.name,
                                    selected = selectedPresetId == preset.id,
                                    accent = previewColor
                                ) {
                                    selectedPresetId = preset.id
                                    name = "${preset.name} Copy"
                                    role = preset.role
                                    instructions = preset.instructions
                                    accentHex = preset.accentHex
                                    shape = preset.avatar.shape
                                    style = preset.avatar.style
                                    face = preset.avatar.face
                                    iconKey = preset.iconKey
                                    notificationsEnabled = preset.notificationsEnabled
                                }
                            }
                        }
                    }
                }

                LabeledGlassTextField("Name", name, "e.g. Research Analyst") { name = it }
                LabeledGlassTextField("Role", role, "e.g. Deep-Dive Synthesis") { role = it }
                LabeledGlassTextField("Custom Instructions", instructions, "How this bot should respond and act…", minLines = 3) {
                    instructions = it
                }

                // Shape Picker
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Profile Shape", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.TextSecondary)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        BotAvatarShape.entries.forEach { candidateShape ->
                            val selected = shape == candidateShape
                            Column(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(if (selected) previewColor.copy(alpha = 0.18f) else BrokColors.ObsidianVoid.copy(alpha = 0.40f))
                                    .border(1.dp, if (selected) previewColor else BrokColors.BorderDim, RoundedCornerShape(14.dp))
                                    .clickable { shape = candidateShape }
                                    .padding(horizontal = 10.dp, vertical = 8.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                BotAvatarView(
                                    avatar = BotAvatarSpec(shape = candidateShape, style = style, face = face),
                                    accentHex = accentHex,
                                    iconKey = iconKey,
                                    size = 30.dp
                                )
                                Text(
                                    text = candidateShape.label,
                                    fontSize = 10.sp,
                                    color = if (selected) BrokColors.TextPrimary else BrokColors.TextSecondary
                                )
                            }
                        }
                    }
                }

                // Color Swatches + Custom Hex
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Color", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.TextSecondary)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        colorSwatches.forEach { swatchHex ->
                            val swatchColor = parseHexColor(swatchHex)
                            val selected = accentHex.equals(swatchHex, ignoreCase = true)
                            Box(
                                modifier = Modifier
                                    .size(26.dp)
                                    .clip(CircleShape)
                                    .background(swatchColor)
                                    .border(if (selected) 2.dp else 0.dp, Color.White, CircleShape)
                                    .clickable { accentHex = swatchHex },
                                contentAlignment = Alignment.Center
                            ) {
                                if (selected) {
                                    Icon(
                                        imageVector = Icons.Rounded.Check,
                                        contentDescription = swatchHex,
                                        tint = Color.Black,
                                        modifier = Modifier.size(14.dp)
                                    )
                                }
                            }
                        }
                    }
                    LabeledGlassTextField("Custom Hex", accentHex, "#00E5FF") { accentHex = it }
                }

                // Face vs Icon Picker
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Face or Icon", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.TextSecondary)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            BotAvatarStyle.entries.forEach { candidateStyle ->
                                PresetChip(
                                    label = candidateStyle.label,
                                    selected = style == candidateStyle,
                                    accent = previewColor
                                ) {
                                    style = candidateStyle
                                }
                            }
                        }
                    }

                    if (style == BotAvatarStyle.FACE) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            BotAvatarFace.entries.forEach { candidateFace ->
                                val selected = face == candidateFace
                                Row(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(if (selected) previewColor.copy(alpha = 0.18f) else BrokColors.ObsidianVoid.copy(alpha = 0.40f))
                                        .border(1.dp, if (selected) previewColor else BrokColors.BorderDim, RoundedCornerShape(12.dp))
                                        .clickable { face = candidateFace }
                                        .padding(horizontal = 10.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    BotAvatarView(
                                        avatar = BotAvatarSpec(shape = shape, style = BotAvatarStyle.FACE, face = candidateFace),
                                        accentHex = accentHex,
                                        iconKey = iconKey,
                                        size = 24.dp
                                    )
                                    Text(
                                        text = candidateFace.label,
                                        fontSize = 11.sp,
                                        color = if (selected) BrokColors.TextPrimary else BrokColors.TextSecondary
                                    )
                                }
                            }
                        }
                    } else {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            iconChoices.forEach { candidateIcon ->
                                val selected = iconKey == candidateIcon
                                Row(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(if (selected) previewColor.copy(alpha = 0.18f) else BrokColors.ObsidianVoid.copy(alpha = 0.40f))
                                        .border(1.dp, if (selected) previewColor else BrokColors.BorderDim, RoundedCornerShape(12.dp))
                                        .clickable { iconKey = candidateIcon }
                                        .padding(horizontal = 10.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    BotAvatarView(
                                        avatar = BotAvatarSpec(shape = shape, style = BotAvatarStyle.ICON, face = face),
                                        accentHex = accentHex,
                                        iconKey = candidateIcon,
                                        size = 24.dp
                                    )
                                    Text(
                                        text = candidateIcon,
                                        fontSize = 11.sp,
                                        color = if (selected) BrokColors.TextPrimary else BrokColors.TextSecondary
                                    )
                                }
                            }
                        }
                    }
                }

                // Needs attention notifications toggle
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(BrokColors.ObsidianVoid.copy(alpha = 0.42f))
                        .border(1.dp, BrokColors.BorderDim, RoundedCornerShape(16.dp))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Needs attention notifications",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium
                        )
                        Text(
                            text = "Allow local alerts for task completion & approvals.",
                            style = MaterialTheme.typography.labelMedium
                        )
                    }
                    Switch(
                        checked = notificationsEnabled,
                        onCheckedChange = { notificationsEnabled = it },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = BrokColors.ObsidianVoid,
                            checkedTrackColor = previewColor
                        )
                    )
                }

                HorizontalDivider(color = BrokColors.BorderDim)

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(if (canSave) previewColor.copy(alpha = 0.24f) else BrokColors.ObsidianVoid.copy(alpha = 0.40f))
                        .border(1.dp, if (canSave) previewColor else BrokColors.BorderDim, RoundedCornerShape(16.dp))
                        .clickable(enabled = canSave) {
                            val normalizedHex = normalizeHexColor(accentHex)
                            val saved = BotPersona(
                                id = existingPersona?.id ?: UUID.randomUUID().toString(),
                                name = name.trim(),
                                role = role.trim(),
                                instructions = instructions.trim(),
                                accentHex = normalizedHex,
                                iconKey = iconKey,
                                avatar = currentAvatar,
                                notificationsEnabled = notificationsEnabled,
                                isDefault = existingPersona?.isDefault ?: false
                            )
                            onSave(saved)
                        }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (existingPersona == null) "Create Bot" else "Save Changes",
                        fontSize = 13.5.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (canSave) BrokColors.TextPrimary else BrokColors.TextSecondary
                    )
                }
            }
        }
    }
}

@Composable
private fun PresetChip(
    label: String,
    selected: Boolean,
    accent: Color,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) accent.copy(alpha = 0.22f) else BrokColors.ObsidianVoid.copy(alpha = 0.40f))
            .border(1.dp, if (selected) accent else BrokColors.BorderDim, RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        if (selected) {
            Icon(
                imageVector = Icons.Rounded.Check,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(12.dp)
            )
        }
        Text(
            text = label,
            fontSize = 11.5.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) BrokColors.TextPrimary else BrokColors.TextSecondary
        )
    }
}

@Composable
private fun LabeledGlassTextField(
    label: String,
    value: String,
    placeholder: String,
    minLines: Int = 1,
    onValueChange: (String) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = BrokColors.TextSecondary)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(BrokColors.ObsidianVoid.copy(alpha = 0.55f))
                .border(1.dp, BrokColors.BorderDim, RoundedCornerShape(14.dp))
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            if (value.isEmpty()) {
                Text(placeholder, fontSize = 12.5.sp, color = BrokColors.TextSecondary.copy(alpha = 0.65f))
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = BrokColors.TextPrimary, fontSize = 13.sp),
                cursorBrush = SolidColor(BrokColors.CyanAccent),
                minLines = minLines,
                maxLines = if (minLines > 1) 5 else 1,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

private fun normalizeHexColor(raw: String): String {
    val cleaned = raw.trim().removePrefix("#")
    return if (cleaned.length == 6 && cleaned.toLongOrNull(16) != null) {
        "#${cleaned.uppercase()}"
    } else {
        "#00E5FF"
    }
}
