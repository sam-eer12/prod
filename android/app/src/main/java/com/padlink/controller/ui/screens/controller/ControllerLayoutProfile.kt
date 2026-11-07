package com.padlink.controller.ui.screens.controller

import android.content.Context
import androidx.core.content.edit

/** Positions are fractions of the usable surface; size is relative to the reference control. */
data class ControlPlacement(val x: Float, val y: Float, val scale: Float) {
    val valid: Boolean get() = x.isFinite() && y.isFinite() && scale.isFinite() &&
        x in 0f..1f && y in 0f..1f && scale in 0.65f..1.65f
}

data class ControllerLayoutProfile(val placements: Map<ControlId, ControlPlacement> = emptyMap()) {
    fun with(id: ControlId, placement: ControlPlacement): ControllerLayoutProfile {
        require(id.kind != ControlKind.ACTION && placement.valid)
        return copy(placements = placements + (id to placement))
    }

    fun encode(): String = (listOf("1") + placements.entries.sortedBy { it.key.ordinal }.map { (id, p) ->
        "${id.name},${p.x},${p.y},${p.scale}"
    }).joinToString("|")

    companion object {
        /** Reject corrupt, duplicate, unknown, or navigation-control entries as a whole. */
        fun decode(value: String): ControllerLayoutProfile? {
            if (value.length > 4096) return null
            val entries = value.split('|')
            if (entries.firstOrNull() != "1" || entries.size > 16) return null
            val placements = mutableMapOf<ControlId, ControlPlacement>()
            for (entry in entries.drop(1)) {
                val fields = entry.split(',')
                if (fields.size != 4) return null
                val id = ControlId.entries.firstOrNull { it.name == fields[0] } ?: return null
                if (id.kind == ControlKind.ACTION || id in placements) return null
                val p = ControlPlacement(fields[1].toFloatOrNull() ?: return null,
                    fields[2].toFloatOrNull() ?: return null, fields[3].toFloatOrNull() ?: return null)
                if (!p.valid) return null
                placements[id] = p
            }
            return ControllerLayoutProfile(placements)
        }
    }
}

object ControllerLayoutPreferences {
    private const val FILE = "controller_layout"
    private const val PROFILE = "profile"

    fun load(context: Context): ControllerLayoutProfile = ControllerLayoutProfile.decode(
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getString(PROFILE, "1") ?: "1",
    ) ?: ControllerLayoutProfile()

    fun save(context: Context, profile: ControllerLayoutProfile) {
        require(ControllerLayoutProfile.decode(profile.encode()) == profile)
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit { putString(PROFILE, profile.encode()) }
    }
}
