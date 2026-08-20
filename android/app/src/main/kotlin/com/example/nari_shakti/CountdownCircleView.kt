package com.example.nari_shakti

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View

/**
 * Custom view that draws an animated circular countdown ring.
 * Used by SosCountdownActivity to show the remaining time.
 */
class CountdownCircleView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    // 0.0 = full circle (just started), 1.0 = empty (time up)
    var progress: Float = 0f
        set(value) {
            field = value.coerceIn(0f, 1f)
            invalidate()
        }

    private val strokeWidth = 12f

    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x33FF5722.toInt() // dim orange background ring
        style = Paint.Style.STROKE
        strokeWidth = this@CountdownCircleView.strokeWidth
        strokeCap = Paint.Cap.ROUND
    }

    private val fgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFF5722.toInt() // bright orange-red foreground arc
        style = Paint.Style.STROKE
        strokeWidth = this@CountdownCircleView.strokeWidth
        strokeCap = Paint.Cap.ROUND
    }

    private val rect = RectF()

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val cx = width / 2f
        val cy = height / 2f
        val radius = minOf(cx, cy) - strokeWidth

        rect.set(cx - radius, cy - radius, cx + radius, cy + radius)

        // Background ring (full circle, dim)
        canvas.drawArc(rect, 0f, 360f, false, bgPaint)

        // Foreground arc (remaining time)
        val sweepAngle = 360f * (1f - progress)
        canvas.drawArc(rect, -90f, sweepAngle, false, fgPaint)
    }
}
