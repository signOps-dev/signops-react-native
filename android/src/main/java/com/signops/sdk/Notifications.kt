package com.signops

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Pushes the SDK draws itself, from your FirebaseMessagingService:
 *
 *     override fun onMessageReceived(m: RemoteMessage) {
 *         if (SignOps.handleMessage(this, m.data, R.drawable.ic_notification)) return
 *         // ...your own pushes
 *     }
 *
 * - A push with buttons arrives as data only (Android cannot draw buttons on an FCM notification) and is drawn here with
 *   them. A tap on the push or a button opens its link, or your app, and reports the open with the button as its action.
 * - An activity (POST /v1/activities) is one ongoing notification per ref, updated in place, quiet after the first.
 * The app needs the POST_NOTIFICATIONS permission on Android 13 and later, as for any notification.
 */
object Notifications {
    const val CHANNEL = "signops"
    const val ACTIVITY_CHANNEL = "signops_activity"

    /** Draws a SignOps push with buttons, or an activity. False for anything else, which your code handles. */
    @JvmStatic @JvmOverloads
    fun handle(context: Context, data: Map<String, String>, smallIcon: Int, channelId: String? = null): Boolean = when {
        data["signops"] == "activity" -> { activity(context, data, smallIcon); true }
        data.containsKey("signops_title") && data.containsKey("signops_buttons") -> { push(context, data, smallIcon, channelId); true }
        else -> false
    }

    private fun channel(context: Context, id: String, name: String, importance: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(id) == null) nm.createNotificationChannel(NotificationChannel(id, name, importance))
    }

    private fun tap(context: Context, req: Int, id: String?, action: String?, link: String?): PendingIntent {
        val i = Intent(context, PushTapActivity::class.java).apply {
            putExtra("signops_id", id); putExtra("signops_action", action); putExtra("signops_link", link)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        }
        return PendingIntent.getActivity(context, req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** The buttons a push carries as data.signops_buttons. */
    @JvmStatic
    fun buttons(data: Map<String, String>): List<Triple<String, String, String?>> {
        val raw = data["signops_buttons"] ?: return emptyList()
        return runCatching {
            val a = JSONArray(raw)
            (0 until a.length()).map { val o = a.getJSONObject(it); Triple(o.getString("id"), o.getString("title"), o.optString("link").ifEmpty { null }) }
        }.getOrDefault(emptyList())
    }

    private fun push(context: Context, data: Map<String, String>, smallIcon: Int, channelId: String?) {
        val ch = channelId ?: data["signops_channel"] ?: CHANNEL
        if (ch == CHANNEL) channel(context, CHANNEL, "Notifications", NotificationManager.IMPORTANCE_HIGH)
        val id = data["signops_id"]
        val notifId = (id ?: data.toString()).hashCode()
        val b = NotificationCompat.Builder(context, ch)
            .setSmallIcon(smallIcon)
            .setContentTitle(data["signops_title"])
            .setContentText(data["signops_body"])
            .setStyle(NotificationCompat.BigTextStyle().bigText(data["signops_body"]))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(tap(context, notifId, id, null, data["link"]))
        data["signops_badge"]?.toIntOrNull()?.let { b.setNumber(it) }
        if (data["signops_sound"] == "none") b.setSilent(true)
        data["signops_image"]?.let { url -> image(url)?.let { bmp -> b.setLargeIcon(bmp).setStyle(NotificationCompat.BigPictureStyle().bigPicture(bmp).setSummaryText(data["signops_body"])) } }
        for ((n, btn) in buttons(data).withIndex()) b.addAction(0, btn.second, tap(context, notifId * 31 + n + 1, id, btn.first, btn.third ?: data["link"]))
        NotificationManagerCompat.from(context).runCatching { notify(notifId, b.build()) }
    }

    /** Downloads the push's image, for at most 5 seconds. onMessageReceived runs off the main thread. */
    private fun image(url: String) = runCatching {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 5000; c.readTimeout = 5000
        c.inputStream.use { BitmapFactory.decodeStream(it) }
    }.getOrNull()

    private fun activity(context: Context, data: Map<String, String>, smallIcon: Int) {
        channel(context, ACTIVITY_CHANNEL, "Live updates", NotificationManager.IMPORTANCE_LOW)
        val ref = data["signops_ref"] ?: return
        val st = runCatching { JSONObject(data["signops_state"] ?: "{}") }.getOrDefault(JSONObject())
        val ended = data["signops_event"] == "end"
        val nm = NotificationManagerCompat.from(context)
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply { putExtra("signops_activity", ref) }
        val b = NotificationCompat.Builder(context, ACTIVITY_CHANNEL)
            .setSmallIcon(smallIcon)
            .setContentTitle(st.optString("title").ifEmpty { null })
            .setContentText(st.optString("body").ifEmpty { null })
            .setOngoing(!ended)
            .setOnlyAlertOnce(true)
            .setAutoCancel(ended)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        if (launch != null) b.setContentIntent(PendingIntent.getActivity(context, ref.hashCode(), launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        if (st.has("progress") && !ended) b.setProgress(100, st.optDouble("progress").toInt().coerceIn(0, 100), false)
        if (ended) b.setTimeoutAfter(3_600_000)
        nm.runCatching { notify("signops_activity", ref.hashCode(), b.build()) }
    }
}

/**
 * A tap on a push the SDK drew: reports the open (with the button as its action), then opens the link or the app.
 * An activity, not a receiver, because Android 12 and later block a receiver from opening an activity after a tap.
 */
class PushTapActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent.getStringExtra("signops_id")
        val action = intent.getStringExtra("signops_action")
        val link = intent.getStringExtra("signops_link")
        if (id != null && id.startsWith("msg_")) SignOps.reportOpen(applicationContext, id, action)
        val next = if (link != null && (link.startsWith("http") || link.contains("://"))) Intent(Intent.ACTION_VIEW, Uri.parse(link))
            else packageManager.getLaunchIntentForPackage(packageName)?.apply { putExtra("signops_action", action) }
        next?.let { runCatching { startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
        finish()
    }
}
