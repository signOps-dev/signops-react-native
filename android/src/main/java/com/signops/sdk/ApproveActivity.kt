package com.signops

import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

/** Colours for the ready-made approve screen, as ARGB ints. Set SignOps.approveColors before it opens. */
data class ApproveColors(
    val accent: Int = 0xFF1F6FEB.toInt(),
    val onAccent: Int = 0xFFFFFFFF.toInt(),
    val background: Int = 0xFFFFFFFF.toInt(),
    val text: Int = 0xFF111111.toInt(),
    val muted: Int = 0xFF5F6368.toInt(),
)

/**
 * The ready-made approve screen: what is being approved, where from, three numbers and "No, it was not me".
 * Open it with signops.approve.open(context), or with a request id from an approve push.
 * It finishes with RESULT_OK and the extra "status" (approved, denied, expired, none) for startActivityForResult callers.
 */
class ApproveActivity : FragmentActivity() {
    private lateinit var signops: SignOps
    private val c get() = SignOps.approveColors
    private lateinit var root: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        signops = SignOps(this, intent.getStringExtra(KEY)!!, intent.getStringExtra(BASE) ?: "https://api.signops.dev")
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(c.background)
            setPadding(dp(24), dp(48), dp(24), dp(32))
        }
        setContentView(root)
        window.statusBarColor = c.background
        load(intent.getStringExtra(REQUEST))
    }

    private fun load(wanted: String?) {
        message("Checking for requests")
        lifecycleScope.launch {
            val list = try { signops.approve.pending() } catch (e: SignOpsException) { return@launch done("none", e.message ?: "Could not reach SignOps.") }
            val r = list.firstOrNull { it.id == wanted } ?: list.firstOrNull()
            if (r == null) done("none", if (wanted != null) "This request was already answered or has expired." else "Nothing is waiting for you.") else show(r)
        }
    }

    private fun show(r: Approve.Request) {
        root.removeAllViews()
        val pay = r.payment
        root.addView(text(if (pay != null) "Approve this payment?" else "Is this you?", 26f, c.text, bold = true))
        root.addView(space(16))
        if (pay != null) {
            root.addView(text(pay.amountText, 34f, c.text, bold = true))
            root.addView(space(4))
            root.addView(text("to ${pay.payee}", 19f, c.text))
        } else root.addView(text(r.context, 19f, c.text))
        val where = listOfNotNull(r.browser, r.city).joinToString(", ")
        if (where.isNotEmpty()) { root.addView(space(6)); root.addView(text(where, 15f, c.muted)) }
        val left = text("", 14f, c.muted)
        root.addView(space(6)); root.addView(left)
        root.addView(space(40))
        root.addView(text("Tap the number shown on the other screen", 15f, c.text))
        root.addView(space(14))

        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val buttons = r.options.map { n ->
            Button(this).apply {
                text = n
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(c.onAccent)
                isAllCaps = false
                background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(c.accent) }
                contentDescription = "Number $n"
                layoutParams = LinearLayout.LayoutParams(0, dp(76), 1f).apply { setMargins(dp(6), 0, dp(6), 0) }
            }
        }
        buttons.forEach(row::addView)
        root.addView(row)
        root.addView(space(28))
        val no = Button(this).apply {
            text = "No, it was not me"
            isAllCaps = false
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(c.text)
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setStroke(dp(1), c.muted); setColor(c.background) }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56))
        }
        root.addView(no)

        fun busy(on: Boolean) { (buttons + no).forEach { it.isEnabled = !on; it.alpha = if (on) 0.5f else 1f } }
        buttons.forEach { b ->
            b.setOnClickListener {
                busy(true)
                lifecycleScope.launch {
                    try {
                        val a = signops.approve.approve(this@ApproveActivity, r, b.text.toString())
                        done(a.status, if (a.status == "approved") "Approved" else "Denied: that number was not the one on the other screen.")
                    } catch (e: SignOpsException) {
                        if (e.code == "cancelled") busy(false) else done(if (e.code == "expired") "expired" else "none", e.message ?: "Could not answer.")
                    }
                }
            }
        }
        no.setOnClickListener {
            busy(true)
            lifecycleScope.launch {
                try { signops.approve.deny(r); done("denied", "Denied. Change your password if you did not try to sign in.") }
                catch (e: SignOpsException) { done("none", e.message ?: "Could not answer.") }
            }
        }

        val ends = runCatching { Instant.parse(r.expiresAt).toEpochMilli() }.getOrDefault(System.currentTimeMillis() + 120_000)
        lifecycleScope.launch {
            while (true) {
                val s = ((ends - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
                left.text = "Expires in ${s / 60}:${(s % 60).toString().padStart(2, '0')}"
                if (s == 0L) { if (buttons.first().isEnabled) done("expired", "This request expired."); break }
                delay(1000)
            }
        }
    }

    private fun message(s: String) {
        root.removeAllViews()
        root.addView(text(s, 17f, c.muted))
    }

    private suspend fun done(status: String, s: String) {
        message(s)
        setResult(RESULT_OK, Intent().putExtra("status", status))
        delay(if (status == "approved") 900 else 2200)
        finish()
    }

    private fun text(s: String, sp: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = s
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.START
    }
    private fun space(h: Int) = View(this).apply { layoutParams = LinearLayout.LayoutParams(1, dp(h)) }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val KEY = "signops.key"
        private const val BASE = "signops.base"
        private const val REQUEST = "signops.request"
        internal fun intent(context: Context, key: String, base: String, requestId: String?) =
            Intent(context, ApproveActivity::class.java).putExtra(KEY, key).putExtra(BASE, base).putExtra(REQUEST, requestId)
    }
}
