package com.padlink.controller.ui.screens.controller

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityEvent
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.customview.widget.ExploreByTouchHelper
import com.padlink.controller.ui.theme.Charcoal
import com.padlink.controller.ui.theme.OffWhite
import com.padlink.controller.ui.theme.PadRed
import androidx.compose.ui.graphics.toArgb
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.roundToInt
import kotlin.math.max

/** Gameplay rendering and multi-touch stay on the View, outside Compose recomposition. */
class ControllerView(context: Context) : View(context) {
    private val input = ControllerInput()
    private val haptics = ControllerHaptics(this)
    var onSettings: () -> Unit = {}
    var onClose: () -> Unit = {}
    var onInputChanged: (ControllerState) -> Unit = {}
    var onLayoutUsableChanged: (Boolean) -> Unit = {}
    var onLayoutFallbackChanged: (Boolean) -> Unit = {}
    var onEditSelection: (ControlId) -> Unit = {}
    var onEditChanged: (ControllerLayoutProfile) -> Unit = {}
    var editing: Boolean = false
        set(value) {
            if (field == value) return
            resetInput()
            field = value
            rebuildLayout()
        }
    var layoutProfile: ControllerLayoutProfile = ControllerLayoutProfile()
        set(value) {
            if (field == value) return
            resetInput()
            field = value
            rebuildLayout()
        }
    var selectedControl: ControlId = ControlId.LEFT_STICK
        set(value) {
            if (field == value) return
            field = value
            accessibility.invalidateRoot()
            invalidate()
        }
    private var editPointer = -1
    private var editOffsetX = 0f
    private var editOffsetY = 0f
    var hapticsEnabled: Boolean
        get() = haptics.enabled
        set(value) { haptics.enabled = value }
    val currentState: ControllerState get() = input.state
    var controllerLayout = ControllerLayout.fit(0f, 0f, resources.displayMetrics.density)
        private set

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = OffWhite.toArgb()
        textAlign = Paint.Align.CENTER
        typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
    }
    private val rect = RectF()
    private val path = Path()
    private var art = emptyMap<ControlId, Artwork>()
    private val accessibility = ControllerAccessibility(this)

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        ViewCompat.setAccessibilityDelegate(this, accessibility)
        setBackgroundColor(Charcoal.toArgb())
    }

    private class Artwork(radius: Float) {
        private val red = PadRed.toArgb()
        val face = LinearGradient(0f, -radius, 0f, radius,
            intArrayOf(ColorUtils.blendARGB(red, Color.WHITE, 0.12f), red, ColorUtils.blendARGB(red, Color.BLACK, 0.25f)),
            null, Shader.TileMode.CLAMP)
        val pressed = LinearGradient(0f, -radius, 0f, radius,
            intArrayOf(ColorUtils.blendARGB(red, Color.BLACK, 0.40f), ColorUtils.blendARGB(red, Color.BLACK, 0.55f)),
            null, Shader.TileMode.CLAMP)
        val well = RadialGradient(0f, radius * 0.16f, radius * 0.94f,
            intArrayOf(0xFF351C20.toInt(), 0xFF231619.toInt(), 0xFF0C090A.toInt()),
            floatArrayOf(0f, 0.76f, 1f), Shader.TileMode.CLAMP)
        private val cap = radius * 0.59f
        val bevel = LinearGradient(-cap, -cap, cap, cap,
            intArrayOf(0xFFFFE5E1.toInt(), 0xFFE1AFB4.toInt(), 0xFF885E65.toInt()),
            floatArrayOf(0f, 0.58f, 1f), Shader.TileMode.CLAMP)
        val lip = LinearGradient(0f, -cap, 0f, cap,
            intArrayOf(0xFFF9D3D3.toInt(), 0xFFC18B93.toInt()), null, Shader.TileMode.CLAMP)
        val groove = LinearGradient(0f, -cap * 0.8f, 0f, cap * 0.8f,
            intArrayOf(0xFF644047.toInt(), 0xFFAE7881.toInt(), 0xFFF3CDCE.toInt()),
            floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP)
        val cup = LinearGradient(0f, -cap * 0.7f, 0f, cap * 0.7f,
            intArrayOf(0xFFB58088.toInt(), 0xFFE9B9BE.toInt(), 0xFFF8D4D5.toInt()),
            floatArrayOf(0f, 0.56f, 1f), Shader.TileMode.CLAMP)
        val clip = Path().apply { addCircle(0f, 0f, radius * 0.94f, Path.Direction.CW) }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        rebuildLayout()
    }

    private fun rebuildLayout() {
        resetInput()
        val requested = ControllerLayout.fit(width.toFloat(), height.toFloat(), resources.displayMetrics.density, layoutProfile)
        val fallback = !editing && !requested.usable && layoutProfile.placements.isNotEmpty()
        controllerLayout = if (fallback) ControllerLayout.fit(width.toFloat(), height.toFloat(), resources.displayMetrics.density) else requested
        art = controllerLayout.controls.associate { it.id to Artwork(it.radius) }
        onLayoutUsableChanged(controllerLayout.usable)
        onLayoutFallbackChanged(fallback)
        accessibility.invalidateRoot()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!controllerLayout.usable && !editing) return
        val state = input.state
        controllerLayout.controls.forEach { control ->
            val artwork = art.getValue(control.id)
            canvas.save()
            canvas.translate(control.x, control.y)
            val pressed = input.isPressed(control.id)
            if (control.id.kind == ControlKind.STICK) {
                val position = if (control.id == ControlId.LEFT_STICK) state.leftStick else state.rightStick
                drawStick(canvas, control, artwork, position)
            } else {
                drawButton(canvas, control, artwork, pressed)
                drawLabel(canvas, control, pressed, state)
            }
            canvas.restore()
            if (editing) {
                paint.shader = null
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 2f * resources.displayMetrics.density
                paint.color = if (control.id != selectedControl) 0x408F969C
                    else if (controllerLayout.usable) OffWhite.toArgb() else 0xFFFFC267.toInt()
                canvas.drawCircle(control.x, control.y, control.touchRadius, paint)
                paint.style = Paint.Style.FILL
            }
        }
    }

    private fun circle(canvas: Canvas, radius: Float, color: Int, shader: Shader? = null, y: Float = 0f) {
        paint.style = Paint.Style.FILL
        paint.color = color
        paint.shader = shader
        canvas.drawCircle(0f, y, radius, paint)
        paint.shader = null
    }

    private fun drawButton(canvas: Canvas, control: ControlGeometry, artwork: Artwork, pressed: Boolean) {
        val r = control.radius
        circle(canvas, r, 0xFF08090A.toInt(), y = r * 0.07f)
        circle(canvas, r, 0xFF4A181D.toInt())
        // Immediate darkening and a slightly sunken face keep repeated presses crisp.
        val faceRadius = r * if (pressed) 0.92f else 0.95f
        circle(canvas, faceRadius, Color.WHITE, if (pressed) artwork.pressed else artwork.face, y = if (pressed) r * 0.025f else 0f)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = r * 0.025f
        paint.color = if (pressed) 0xFF3A0E14.toInt() else 0x40F5A2A0
        rect.set(-faceRadius, -faceRadius, faceRadius, faceRadius)
        canvas.drawArc(rect, 205f, 125f, false, paint)
        paint.style = Paint.Style.FILL
    }

    private fun drawStick(canvas: Canvas, control: ControlGeometry, artwork: Artwork, position: StickPosition) {
        val r = control.radius
        circle(canvas, r, 0xFF08090A.toInt(), y = r * 0.055f)
        circle(canvas, r, 0xFF4A181D.toInt())
        circle(canvas, r * 0.965f, Color.WHITE, artwork.face)
        circle(canvas, r * 0.88f, Color.WHITE, artwork.well)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = r * 0.018f
        paint.color = 0x507C454B
        rect.set(-r * 0.88f, -r * 0.88f, r * 0.88f, r * 0.88f)
        canvas.drawArc(rect, 12f, 154f, false, paint)
        paint.style = Paint.Style.FILL

        canvas.save()
        canvas.clipPath(artwork.clip)
        canvas.translate(position.x * control.travel, position.y * control.travel)
        val cap = control.capRadius
        circle(canvas, cap * 1.09f, 0x30000000, y = cap * 0.16f)
        circle(canvas, cap * 1.04f, 0x50000000, y = cap * 0.10f)
        circle(canvas, cap, Color.WHITE, artwork.bevel)
        circle(canvas, cap * 0.92f, Color.WHITE, artwork.lip)
        // Inset dark upper edge and light lower edge create the inward thumb groove.
        circle(canvas, cap * 0.79f, Color.WHITE, artwork.groove)
        circle(canvas, cap * 0.68f, Color.WHITE, artwork.cup)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = cap * 0.018f
        paint.color = 0x50764953
        canvas.drawCircle(0f, 0f, cap * 0.78f, paint)
        paint.style = Paint.Style.FILL
        canvas.restore()
    }

    private fun drawLabel(canvas: Canvas, control: ControlGeometry, pressed: Boolean, state: ControllerState) {
        val r = control.radius
        labelPaint.color = if (pressed) 0xFFE8C8C6.toInt() else OffWhite.toArgb()
        labelPaint.textSize = r * 0.65f
        when (control.id) {
            ControlId.LT, ControlId.RT, ControlId.LB, ControlId.RB,
            ControlId.A, ControlId.B, ControlId.X, ControlId.Y -> {
                textCentered(canvas, control.id.name, 0f)
                if (control.id.kind == ControlKind.TRIGGER) {
                    val value = if (control.id == ControlId.LT) state.leftTrigger else state.rightTrigger
                    if (value > 0f) {
                        paint.style = Paint.Style.STROKE
                        paint.strokeWidth = r * 0.065f
                        paint.strokeCap = Paint.Cap.ROUND
                        paint.color = 0xFFEDB2B4.toInt()
                        rect.set(-r * 0.78f, -r * 0.78f, r * 0.78f, r * 0.78f)
                        canvas.drawArc(rect, 135f, value * 270f, false, paint)
                        paint.style = Paint.Style.FILL
                    }
                }
            }
            ControlId.L3, ControlId.R3 -> {
                labelPaint.textSize = r * 0.47f
                textCentered(canvas, if (control.id == ControlId.L3) "Left" else "Right", -r * 0.23f)
                textCentered(canvas, "Stick", r * 0.29f)
            }
            ControlId.CLOSE -> {
                iconPaint(r)
                val d = r * 0.31f
                canvas.drawLine(-d, -d, d, d, paint)
                canvas.drawLine(-d, d, d, -d, paint)
            }
            ControlId.MENU -> {
                iconPaint(r)
                for (i in -1..1) canvas.drawLine(-r * 0.37f, i * r * 0.23f, r * 0.37f, i * r * 0.23f, paint)
            }
            ControlId.VIEW -> {
                iconPaint(r)
                for (i in -1..0) {
                    rect.set(-r * 0.28f, i * r * 0.43f + r * 0.07f, r * 0.28f, i * r * 0.43f + r * 0.35f)
                    canvas.drawRoundRect(rect, r * 0.05f, r * 0.05f, paint)
                }
            }
            ControlId.SETTINGS -> drawGear(canvas, r)
            ControlId.DPAD -> drawDpad(canvas, r, state.buttons)
            else -> Unit
        }
        paint.style = Paint.Style.FILL
    }

    private fun textCentered(canvas: Canvas, text: String, y: Float) {
        canvas.drawText(text, 0f, y - (labelPaint.ascent() + labelPaint.descent()) / 2f, labelPaint)
    }

    private fun iconPaint(radius: Float) {
        paint.shader = null
        paint.style = Paint.Style.STROKE
        paint.color = OffWhite.toArgb()
        paint.strokeWidth = radius * 0.07f
        paint.strokeCap = Paint.Cap.ROUND
        paint.strokeJoin = Paint.Join.ROUND
    }

    private fun drawGear(canvas: Canvas, r: Float) {
        iconPaint(r)
        canvas.drawCircle(0f, 0f, r * 0.16f, paint)
        canvas.drawCircle(0f, 0f, r * 0.36f, paint)
        for (i in 0 until 8) {
            val angle = i * Math.PI / 4.0
            val x = cos(angle).toFloat()
            val y = sin(angle).toFloat()
            canvas.drawLine(x * r * 0.35f, y * r * 0.35f, x * r * 0.47f, y * r * 0.47f, paint)
        }
    }

    private fun drawDpad(canvas: Canvas, r: Float, buttons: Int) {
        val masks = intArrayOf(1 shl 11, 1 shl 14, 1 shl 12, 1 shl 13)
        for (i in 0 until 4) {
            canvas.save()
            canvas.rotate(i * 90f)
            if (buttons and masks[i] != 0) {
                paint.style = Paint.Style.FILL
                paint.color = 0x40FFC5C7
                rect.set(-r * 0.89f, -r * 0.89f, r * 0.89f, r * 0.89f)
                canvas.drawArc(rect, 235f, 70f, true, paint)
            }
            iconPaint(r)
            paint.strokeWidth = r * 0.06f
            path.reset()
            path.moveTo(-r * 0.14f, -r * 0.59f)
            path.lineTo(0f, -r * 0.73f)
            path.lineTo(r * 0.14f, -r * 0.59f)
            canvas.drawPath(path, paint)
            canvas.restore()
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (editing) return editTouch(event)
        if (!controllerLayout.usable) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) resetInput()
                val index = event.actionIndex
                val control = controllerLayout.hitTest(event.getX(index), event.getY(index))
                if (control != null && input.press(event.getPointerId(index), control, event.getX(index), event.getY(index))) {
                    parent?.requestDisallowInterceptTouchEvent(true)
                    if (control.id.kind == ControlKind.STICK) feedbackForStick(control.id)
                    else haptics.buttonPress()
                }
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until event.pointerCount) {
                    val id = event.getPointerId(i)
                    val control = input.controlFor(id) ?: continue
                    val before = input.state.buttons
                    input.move(id, event.getX(i), event.getY(i))
                    if (control.kind == ControlKind.STICK) feedbackForStick(control)
                    if (control == ControlId.DPAD && input.state.buttons != before) haptics.buttonPress()
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val pointerId = event.getPointerId(event.actionIndex)
                val control = input.controlFor(pointerId)
                input.move(pointerId, event.getX(event.actionIndex), event.getY(event.actionIndex))
                val activate = control?.kind == ControlKind.ACTION && input.isPressed(control)
                input.release(pointerId)
                if (control?.kind == ControlKind.STICK) haptics.releaseStick(control)
                if (activate) {
                    performClick()
                    activateAction(requireNotNull(control))
                }
                if (event.actionMasked == MotionEvent.ACTION_UP) parent?.requestDisallowInterceptTouchEvent(false)
            }
            MotionEvent.ACTION_CANCEL -> {
                resetInput()
                parent?.requestDisallowInterceptTouchEvent(false)
            }
        }
        onInputChanged(input.state)
        invalidate()
        return true
    }

    /** Editor gestures never reach ControllerInput or the Bluetooth input callback. */
    private fun editTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val control = controllerLayout.controls.lastOrNull {
                    it.id.kind != ControlKind.ACTION && it.contains(event.x, event.y)
                } ?: return true
                selectedControl = control.id
                onEditSelection(control.id)
                editPointer = event.getPointerId(0)
                editOffsetX = event.x - control.x
                editOffsetY = event.y - control.y
                parent?.requestDisallowInterceptTouchEvent(true)
            }
            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(editPointer)
                if (index >= 0) placeControl(selectedControl, event.getX(index) - editOffsetX, event.getY(index) - editOffsetY)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                editPointer = -1
                parent?.requestDisallowInterceptTouchEvent(false)
                if (event.actionMasked == MotionEvent.ACTION_UP) performClick()
            }
            MotionEvent.ACTION_POINTER_UP -> if (event.getPointerId(event.actionIndex) == editPointer) editPointer = -1
        }
        return true
    }

    fun adjustSelected(dxDp: Float = 0f, dyDp: Float = 0f, scale: Float? = null) {
        if (!editing || controllerLayout.controls.isEmpty()) return
        val g = controllerLayout[selectedControl]
        val density = resources.displayMetrics.density
        placeControl(selectedControl, g.x + dxDp * density, g.y + dyDp * density, scale)
    }

    private fun placeControl(id: ControlId, x: Float, y: Float, scale: Float? = null) {
        if (!editing || id.kind == ControlKind.ACTION || width <= 0 || height <= 0) return
        val g = controllerLayout[id]
        val oldScale = layoutProfile.placements[id]?.scale ?: 1f
        val newScale = (scale ?: oldScale).coerceIn(0.65f, 1.65f)
        val target = max(g.radius / oldScale * newScale, 24f * resources.displayMetrics.density)
        if (target * 2 > width || target * 2 > height) return
        val placement = ControlPlacement(x.coerceIn(target, width - target) / width,
            y.coerceIn(target, height - target) / height, newScale)
        layoutProfile = layoutProfile.with(id, placement)
        onEditChanged(layoutProfile)
    }

    private fun feedbackForStick(id: ControlId) {
        val state = input.state
        haptics.stickMoved(id, if (id == ControlId.LEFT_STICK) state.leftStick else state.rightStick)
    }

    override fun performClick(): Boolean { super.performClick(); return true }

    private fun activateAction(id: ControlId) {
        resetInput()
        when (id) {
            ControlId.SETTINGS -> onSettings()
            ControlId.CLOSE -> onClose()
            else -> Unit
        }
    }

    fun resetInput() {
        input.reset()
        haptics.stop()
        onInputChanged(input.state)
        invalidate()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) resetInput()
    }

    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        super.onVisibilityChanged(changedView, visibility)
        // View's constructor may call this override before field initialization.
        if (visibility != VISIBLE && isAttachedToWindow) resetInput()
    }

    override fun onDetachedFromWindow() {
        resetInput()
        super.onDetachedFromWindow()
    }

    override fun dispatchHoverEvent(event: MotionEvent): Boolean =
        accessibility.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        accessibility.dispatchKeyEvent(event) || super.dispatchKeyEvent(event)

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        accessibility.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        if (!gainFocus) resetInput()
    }

    private inner class ControllerAccessibility(host: View) : ExploreByTouchHelper(host) {
        override fun getVirtualViewAt(x: Float, y: Float): Int =
            if (editing) controllerLayout.controls.lastOrNull { it.id.kind != ControlKind.ACTION && it.contains(x, y) }?.id?.ordinal ?: INVALID_ID
            else controllerLayout.hitTest(x, y)?.id?.ordinal ?: INVALID_ID

        override fun getVisibleVirtualViews(virtualViewIds: MutableList<Int>) {
            if (controllerLayout.usable || editing) controllerLayout.controls.filter { !editing || it.id.kind != ControlKind.ACTION }
                .forEach { virtualViewIds.add(it.id.ordinal) }
        }

        @Suppress("DEPRECATION") // ExploreByTouchHelper requires parent bounds to derive screen bounds.
        override fun onPopulateNodeForVirtualView(virtualViewId: Int, node: AccessibilityNodeInfoCompat) {
            val id = ControlId.entries[virtualViewId]
            val g = controllerLayout[id]
            node.contentDescription = id.label
            val directional = id.kind == ControlKind.STICK || id.kind == ControlKind.DPAD
            node.className = if (id.kind == ControlKind.STICK || id.kind == ControlKind.TRIGGER) "android.widget.SeekBar" else "android.widget.Button"
            node.isClickable = !directional
            node.isFocusable = true
            node.setBoundsInParent(Rect((g.x - g.touchRadius).toInt(), (g.y - g.touchRadius).toInt(),
                (g.x + g.touchRadius).toInt(), (g.y + g.touchRadius).toInt()))
            if (editing) {
                node.className = "android.widget.Button"
                node.isClickable = true
                node.isSelected = selectedControl == id
                node.stateDescription = "Select to move or resize."
                node.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_CLICK)
                return
            }
            if (directional) {
                node.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_UP.id, "Move up"))
                node.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_DOWN.id, "Move down"))
                node.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_LEFT.id, "Move left"))
                node.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_RIGHT.id, "Move right"))
            } else node.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_CLICK)
            val state = input.state
            node.stateDescription = when (id.kind) {
                ControlKind.STICK -> {
                    val position = if (id == ControlId.LEFT_STICK) state.leftStick else state.rightStick
                    if (position.magnitude < 0.01f) "Centered. Drag to move."
                    else "Horizontal ${(position.x * 100).roundToInt()} percent. Vertical ${(-position.y * 100).roundToInt()} percent."
                }
                ControlKind.TRIGGER -> {
                    val value = if (id == ControlId.LT) state.leftTrigger else state.rightTrigger
                    "${(value * 100).roundToInt()} percent. Tap for full pull. Drag down to adjust."
                }
                ControlKind.DPAD -> "Drag in a direction."
                else -> if (input.isPressed(id)) "Pressed" else "Released"
            }
        }

        override fun onPerformActionForVirtualView(virtualViewId: Int, action: Int, arguments: Bundle?): Boolean {
            val id = ControlId.entries.getOrNull(virtualViewId) ?: return false
            if (editing) {
                if (id.kind == ControlKind.ACTION || action != AccessibilityNodeInfoCompat.ACTION_CLICK) return false
                selectedControl = id
                onEditSelection(id)
                sendEventForVirtualView(virtualViewId, AccessibilityEvent.TYPE_VIEW_CLICKED)
                return true
            }
            if (!controllerLayout.usable) return false
            if (id.kind == ControlKind.ACTION && action == AccessibilityNodeInfoCompat.ACTION_CLICK) {
                haptics.buttonPress()
                activateAction(id)
            } else {
                val g = controllerLayout[id]
                val directional = id.kind == ControlKind.STICK || id.kind == ControlKind.DPAD
                val distance = if (id.kind == ControlKind.STICK) g.travel else g.radius * 0.7f
                var x = g.x
                var y = g.y
                when (action) {
                    AccessibilityNodeInfoCompat.ACTION_CLICK -> if (directional || id.kind == ControlKind.ACTION) return false
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_UP.id -> { if (!directional) return false; y -= distance }
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_DOWN.id -> { if (!directional) return false; y += distance }
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_LEFT.id -> { if (!directional) return false; x -= distance }
                    AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_SCROLL_RIGHT.id -> { if (!directional) return false; x += distance }
                    else -> return false
                }
                val pointer = -1 - virtualViewId
                if (!input.press(pointer, g, x, y)) return false
                if (id.kind == ControlKind.STICK) feedbackForStick(id) else haptics.buttonPress()
                onInputChanged(input.state)
                invalidate()
                postDelayed({
                    input.release(pointer)
                    if (id.kind == ControlKind.STICK) haptics.releaseStick(id)
                    onInputChanged(input.state)
                    invalidate()
                    invalidateVirtualView(virtualViewId)
                }, 100L)
            }
            sendEventForVirtualView(virtualViewId, AccessibilityEvent.TYPE_VIEW_CLICKED)
            return true
        }
    }
}
