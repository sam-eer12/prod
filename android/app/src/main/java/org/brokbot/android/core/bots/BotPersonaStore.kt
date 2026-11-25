package org.brokbot.android.core.bots

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

enum class BotAvatarShape(val label: String) {
    CIRCLE("Circle"),
    ROUNDED_SQUARE("Rounded Square"),
    SOFT_TRIANGLE("Soft Triangle"),
    CLOUD("Cloud"),
    PEBBLE("Pebble");

    companion object {
        fun fromRaw(raw: String?): BotAvatarShape =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: CIRCLE
    }
}

enum class BotAvatarStyle(val label: String) {
    FACE("Face"),
    ICON("Icon");

    companion object {
        fun fromRaw(raw: String?): BotAvatarStyle =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: FACE
    }
}

enum class BotAvatarFace(val label: String) {
    DOTS("Classic Dots"),
    HAPPY("Happy Eyes"),
    FOCUSED("Focused"),
    WINK("Wink"),
    VISOR("Visor"),
    MONOCLE("Monocle");

    companion object {
        fun fromRaw(raw: String?): BotAvatarFace =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: DOTS
    }
}

data class BotAvatarSpec(
    val shape: BotAvatarShape = BotAvatarShape.CIRCLE,
    val style: BotAvatarStyle = BotAvatarStyle.FACE,
    val face: BotAvatarFace = BotAvatarFace.DOTS
) {
    fun toJsonMap(): Map<String, Any> = linkedMapOf(
        "shape" to shape.name,
        "style" to style.name,
        "face" to face.name
    )

    companion object {
        fun fromJsonMap(map: Map<*, *>?): BotAvatarSpec {
            if (map == null) {
                return BotAvatarSpec(
                    shape = BotAvatarShape.CIRCLE,
                    style = BotAvatarStyle.ICON,
                    face = BotAvatarFace.DOTS
                )
            }
            return BotAvatarSpec(
                shape = BotAvatarShape.fromRaw(map["shape"] as? String),
                style = BotAvatarStyle.fromRaw(map["style"] as? String),
                face = BotAvatarFace.fromRaw(map["face"] as? String)
            )
        }
    }
}

data class BotPersona(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val role: String,
    val instructions: String,
    val accentHex: String = "#00E5FF",
    val iconKey: String = "sparkles",
    val avatar: BotAvatarSpec = BotAvatarSpec(),
    val notificationsEnabled: Boolean = true,
    val isDefault: Boolean = false
) {
    fun toJsonMap(): Map<String, Any> = linkedMapOf(
        "id" to id,
        "name" to name,
        "role" to role,
        "instructions" to instructions,
        "accentHex" to accentHex,
        "iconKey" to iconKey,
        "avatar" to avatar.toJsonMap(),
        "notificationsEnabled" to notificationsEnabled,
        "isDefault" to isDefault
    )

    companion object {
        val chiefOfStaff = BotPersona(
            id = "chief-of-staff",
            name = "Chief of Staff",
            role = "Primary Orchestrator",
            instructions = "Coordinate tasks cleanly, respect Dual-Space memory boundaries, and keep responses crisp and actionable.",
            accentHex = "#00E5FF",
            iconKey = "sparkles",
            avatar = BotAvatarSpec(
                shape = BotAvatarShape.CIRCLE,
                style = BotAvatarStyle.FACE,
                face = BotAvatarFace.MONOCLE
            ),
            notificationsEnabled = true,
            isDefault = true
        )

        val threeDArtist = BotPersona(
            id = "3d-artist",
            name = "3D Artist",
            role = "Blender & Spatial Specialist",
            instructions = "Design clean 3D scenes, lighting rigs, and material workflows with explicit approval before write steps.",
            accentHex = "#FF9F0A",
            iconKey = "cube",
            avatar = BotAvatarSpec(
                shape = BotAvatarShape.SOFT_TRIANGLE,
                style = BotAvatarStyle.FACE,
                face = BotAvatarFace.VISOR
            ),
            notificationsEnabled = true,
            isDefault = false
        )

        val inboxTriage = BotPersona(
            id = "inbox-triage",
            name = "Inbox Triage",
            role = "Email & Calendar Specialist",
            instructions = "Prioritize unread threads, spot scheduling conflicts, and draft concise executive summaries.",
            accentHex = "#34D399",
            iconKey = "tray",
            avatar = BotAvatarSpec(
                shape = BotAvatarShape.CLOUD,
                style = BotAvatarStyle.FACE,
                face = BotAvatarFace.HAPPY
            ),
            notificationsEnabled = true,
            isDefault = false
        )

        val presets: List<BotPersona> = listOf(chiefOfStaff, threeDArtist, inboxTriage)

        fun fromJsonMap(map: Map<*, *>): BotPersona? {
            val id = (map["id"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val name = (map["name"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val avatarMap = map["avatar"] as? Map<*, *>
            val notifications = (map["notificationsEnabled"] as? Boolean) ?: true
            return BotPersona(
                id = id,
                name = name,
                role = (map["role"] as? String) ?: "Specialist",
                instructions = (map["instructions"] as? String) ?: "",
                accentHex = (map["accentHex"] as? String) ?: "#00E5FF",
                iconKey = (map["iconKey"] as? String) ?: "sparkles",
                // Older records without avatar keep saved accentHex + iconKey with a default circle+icon avatar.
                avatar = BotAvatarSpec.fromJsonMap(avatarMap),
                notificationsEnabled = notifications,
                isDefault = (map["isDefault"] as? Boolean) ?: false
            )
        }

        fun encodeList(list: List<BotPersona>): String =
            PureJsonCodec.encodeValue(list.map { it.toJsonMap() })

        fun decodeList(rawJson: String): List<BotPersona> {
            val parsed = PureJsonCodec.parse(rawJson) as? List<*> ?: return emptyList()
            return parsed.mapNotNull { item ->
                val map = item as? Map<*, *> ?: return@mapNotNull null
                fromJsonMap(map)
            }
        }
    }
}

private object PureJsonCodec {
    fun encodeValue(value: Any?): String = when (value) {
        null -> "null"
        is Boolean, is Number -> value.toString()
        is String -> encodeString(value)
        is Map<*, *> -> value.entries.joinToString(prefix = "{", postfix = "}", separator = ",") { (k, v) ->
            "${encodeString(k.toString())}:${encodeValue(v)}"
        }
        is Iterable<*> -> value.joinToString(prefix = "[", postfix = "]", separator = ",") { encodeValue(it) }
        else -> encodeString(value.toString())
    }

    private fun encodeString(s: String): String = buildString(s.length + 2) {
        append('"')
        for (ch in s) {
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> append(ch)
            }
        }
        append('"')
    }

    fun parse(input: String): Any? {
        val parser = Parser(input)
        val value = parser.readValue()
        parser.skipWhitespace()
        return value
    }

    private class Parser(private val src: String) {
        private var pos = 0

        fun skipWhitespace() {
            while (pos < src.length && src[pos].isWhitespace()) pos++
        }

        fun readValue(): Any? {
            skipWhitespace()
            if (pos >= src.length) error("Unexpected end of JSON")
            return when (val ch = src[pos]) {
                '{' -> readObject()
                '[' -> readArray()
                '"' -> readString()
                't' -> expectLiteral("true", true)
                'f' -> expectLiteral("false", false)
                'n' -> expectLiteral("null", null)
                '-', in '0'..'9' -> readNumber()
                else -> error("Unexpected char '$ch' at $pos")
            }
        }

        private fun readObject(): Map<String, Any?> {
            pos++ // '{'
            val map = linkedMapOf<String, Any?>()
            skipWhitespace()
            if (pos < src.length && src[pos] == '}') {
                pos++
                return map
            }
            while (pos < src.length) {
                skipWhitespace()
                val key = readString()
                skipWhitespace()
                require(pos < src.length && src[pos] == ':') { "Expected ':' at $pos" }
                pos++
                val value = readValue()
                map[key] = value
                skipWhitespace()
                if (pos < src.length && src[pos] == ',') {
                    pos++
                    continue
                }
                if (pos < src.length && src[pos] == '}') {
                    pos++
                    return map
                }
                error("Expected ',' or '}' at $pos")
            }
            error("Unterminated object")
        }

        private fun readArray(): List<Any?> {
            pos++ // '['
            val list = mutableListOf<Any?>()
            skipWhitespace()
            if (pos < src.length && src[pos] == ']') {
                pos++
                return list
            }
            while (pos < src.length) {
                list.add(readValue())
                skipWhitespace()
                if (pos < src.length && src[pos] == ',') {
                    pos++
                    continue
                }
                if (pos < src.length && src[pos] == ']') {
                    pos++
                    return list
                }
                error("Expected ',' or ']' at $pos")
            }
            error("Unterminated array")
        }

        private fun readString(): String {
            require(pos < src.length && src[pos] == '"') { "Expected '\"' at $pos" }
            pos++
            val sb = StringBuilder()
            while (pos < src.length) {
                val ch = src[pos++]
                if (ch == '"') return sb.toString()
                if (ch == '\\' && pos < src.length) {
                    when (val esc = src[pos++]) {
                        '"', '\\', '/' -> sb.append(esc)
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        'u' -> {
                            val hex = src.substring(pos, minOf(pos + 4, src.length))
                            sb.append(hex.toInt(16).toChar())
                            pos += 4
                        }
                        else -> sb.append(esc)
                    }
                } else {
                    sb.append(ch)
                }
            }
            error("Unterminated string")
        }

        private fun readNumber(): Number {
            val start = pos
            while (pos < src.length && src[pos] in "-0123456789.eE+") pos++
            val token = src.substring(start, pos)
            return token.toLongOrNull() ?: token.toDouble()
        }

        private fun expectLiteral(lit: String, result: Any?): Any? {
            require(src.startsWith(lit, pos)) { "Expected $lit at $pos" }
            pos += lit.length
            return result
        }
    }
}

class BotPersonaStore(context: Context? = null) {
    private val prefs = context?.applicationContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val lock = Any()

    private val _personasFlow = MutableStateFlow(loadInitialPersonas())
    val personasFlow: StateFlow<List<BotPersona>> = _personasFlow.asStateFlow()

    private val _selectedPersonaFlow = MutableStateFlow(loadInitialSelected(_personasFlow.value))
    val selectedPersonaFlow: StateFlow<BotPersona> = _selectedPersonaFlow.asStateFlow()

    fun personas(): List<BotPersona> = synchronized(lock) { _personasFlow.value }

    fun selectedPersona(): BotPersona = synchronized(lock) { _selectedPersonaFlow.value }

    fun selectBot(botId: String): BotPersona? = synchronized(lock) {
        val found = _personasFlow.value.firstOrNull { it.id == botId } ?: return@synchronized null
        _selectedPersonaFlow.value = found
        prefs?.edit()?.putString(KEY_SELECTED_ID, found.id)?.apply()
        found
    }

    fun createBot(persona: BotPersona): BotPersona = synchronized(lock) {
        val next = _personasFlow.value + persona
        _personasFlow.value = next
        _selectedPersonaFlow.value = persona
        persistLocked(next, persona.id)
        persona
    }

    fun updateBot(persona: BotPersona): BotPersona = synchronized(lock) {
        val current = _personasFlow.value.toMutableList()
        val idx = current.indexOfFirst { it.id == persona.id }
        val updatedPersona = if (idx >= 0) {
            persona.copy(isDefault = current[idx].isDefault)
        } else {
            persona
        }
        if (idx >= 0) {
            current[idx] = updatedPersona
        } else {
            current.add(updatedPersona)
        }
        _personasFlow.value = current
        if (_selectedPersonaFlow.value.id == updatedPersona.id) {
            _selectedPersonaFlow.value = updatedPersona
        }
        persistLocked(current, _selectedPersonaFlow.value.id)
        updatedPersona
    }

    fun deleteBot(botId: String): Boolean = synchronized(lock) {
        val target = _personasFlow.value.firstOrNull { it.id == botId } ?: return@synchronized false
        if (target.isDefault) return@synchronized false
        val remaining = _personasFlow.value.filterNot { it.id == botId }
        _personasFlow.value = remaining
        if (_selectedPersonaFlow.value.id == botId) {
            _selectedPersonaFlow.value = remaining.firstOrNull() ?: BotPersona.chiefOfStaff
        }
        persistLocked(remaining, _selectedPersonaFlow.value.id)
        true
    }

    private fun loadInitialPersonas(): List<BotPersona> {
        val saved = prefs?.getString(KEY_PERSONAS_JSON, null) ?: return BotPersona.presets
        val decoded = runCatching { BotPersona.decodeList(saved) }.getOrNull()
        if (decoded.isNullOrEmpty()) return BotPersona.presets
        val decodedById = decoded.associateBy { it.id }
        val presetIds = BotPersona.presets.map { it.id }.toSet()
        val merged = BotPersona.presets.map { preset ->
            decodedById[preset.id]?.copy(isDefault = preset.isDefault) ?: preset
        }.toMutableList()
        decoded.filter { it.id !in presetIds }.forEach { merged.add(it) }
        return merged
    }

    private fun loadInitialSelected(personas: List<BotPersona>): BotPersona {
        val savedId = prefs?.getString(KEY_SELECTED_ID, null)
        return personas.firstOrNull { it.id == savedId } ?: personas.firstOrNull() ?: BotPersona.chiefOfStaff
    }

    private fun persistLocked(personas: List<BotPersona>, selectedId: String) {
        prefs?.edit()
            ?.putString(KEY_PERSONAS_JSON, BotPersona.encodeList(personas))
            ?.putString(KEY_SELECTED_ID, selectedId)
            ?.apply()
    }

    companion object {
        private const val PREFS_NAME = "brok_bot_personas_v1"
        private const val KEY_PERSONAS_JSON = "personas_json"
        private const val KEY_SELECTED_ID = "selected_persona_id"
    }
}
