package com.signops

import android.content.Intent
import org.json.JSONObject

/**
 * Push opens. Every push SignOps sends carries its message id as data.signops_id; report the open and it shows on the
 * message in the dashboard and as a push.opened webhook. Your app still gets its push token from Firebase and your
 * server registers it (POST /v1/devices): no SignOps SDK is needed to receive pushes.
 *
 *     // a tap on a notification your app drew, from RemoteMessage.data
 *     signops.push.opened(remoteMessage.data)
 *     // a tap on a notification the system drew while the app slept: the data arrives as the launch intent's extras
 *     signops.push.opened(intent)
 *     // a tap on one of its buttons
 *     signops.push.opened(remoteMessage.data, action = "track")
 */
class Push internal constructor(private val signops: SignOps) {
    /** Reports the open. Returns false, without a call, when the data is not from a SignOps push. */
    suspend fun opened(data: Map<String, String?>, action: String? = null): Boolean {
        val id = messageId(data) ?: return false
        report(id, action)
        return true
    }

    /** The same, from a launch intent. Returns false when the intent did not come from a SignOps push. */
    suspend fun opened(intent: Intent?, action: String? = null): Boolean {
        val id = intent?.extras?.getString("signops_id") ?: return false
        report(id, action ?: intent.extras?.getString("signops_action"))
        // Opening the same activity again with the same intent must not count twice.
        intent.removeExtra("signops_id")
        return true
    }

    private suspend fun report(id: String, action: String?) {
        val body = JSONObject().put("platform", "android")
        if (action != null) body.put("action", action)
        signops.post("/v1/push/$id/opened", body)
    }

    companion object {
        /** The SignOps message id in a push's data, or null for a push that did not come through SignOps. */
        @JvmStatic fun messageId(data: Map<String, String?>): String? = data["signops_id"]?.takeIf { it.startsWith("msg_") }
    }
}
