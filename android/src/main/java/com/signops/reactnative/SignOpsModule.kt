package com.signops.reactnative

import androidx.fragment.app.FragmentActivity
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.signops.Approve
import com.signops.SignOps
import com.signops.SignOpsException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** The bridge: each call names the publishable key, and the native SDK does the work. */
class SignOpsModule(private val ctx: ReactApplicationContext) : ReactContextBaseJavaModule(ctx) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val clients = HashMap<String, SignOps>()

    override fun getName() = "SignOpsRN"

    private fun client(key: String, base: String) = synchronized(clients) { clients.getOrPut("$key $base") { SignOps(ctx, key, base) } }

    private fun run(p: Promise, block: suspend () -> Any?) {
        scope.launch {
            try { p.resolve(block()) }
            catch (e: SignOpsException) { p.reject(e.code, e.message, e, Arguments.createMap().apply { putInt("status", e.status) }) }
            catch (e: IllegalArgumentException) { p.reject("invalid_key", e.message, e) }
            catch (e: Exception) { p.reject("error", e.message ?: e.toString(), e) }
        }
    }

    private fun activity(): FragmentActivity = currentActivity as? FragmentActivity
        ?: throw SignOpsException(0, "no_activity", "SignOps needs the app on screen (a FragmentActivity, which ReactActivity is).")

    private fun request(m: ReadableMap) = Approve.Request(
        m.getString("id")!!, m.getString("context") ?: "", m.getString("city"), m.getString("browser"),
        m.getArray("options")?.toArrayList()?.map { it.toString() } ?: emptyList(), m.getString("createdAt") ?: "", m.getString("expiresAt") ?: "",
        if (m.hasKey("payment") && !m.isNull("payment")) m.getMap("payment")?.let { p -> Approve.Payment(p.getString("amount") ?: "", p.getString("currency") ?: "", p.getString("payee") ?: "") } else null,
    )

    private fun requestMap(r: Approve.Request): WritableMap = Arguments.createMap().apply {
        putString("id", r.id); putString("context", r.context); putString("city", r.city); putString("browser", r.browser)
        putArray("options", Arguments.fromList(r.options)); putString("createdAt", r.createdAt); putString("expiresAt", r.expiresAt)
        r.payment?.let { p -> putMap("payment", Arguments.createMap().apply { putString("amount", p.amount); putString("currency", p.currency); putString("payee", p.payee) }) } ?: putNull("payment")
    }

    private fun answerMap(a: Approve.Answer): WritableMap = Arguments.createMap().apply { putString("id", a.id); putString("status", a.status); putString("reason", a.reason) }

    private fun strings(m: ReadableMap?): Map<String, String?> = m?.toHashMap()?.mapValues { it.value?.toString() } ?: emptyMap()

    @ReactMethod fun approveStatus(key: String, base: String, p: Promise) = run(p) {
        val a = client(key, base).approve
        Arguments.createMap().apply { putBoolean("enrolled", a.isEnrolled); putString("deviceId", a.deviceId); putString("userId", a.userId) }
    }

    @ReactMethod fun approveEnroll(key: String, base: String, token: String, pushToken: String, name: String?, p: Promise) = run(p) {
        val e = if (name != null) client(key, base).approve.enroll(token, pushToken, name) else client(key, base).approve.enroll(token, pushToken)
        Arguments.createMap().apply { putString("deviceId", e.deviceId); putString("userId", e.userId) }
    }

    @ReactMethod fun approvePending(key: String, base: String, p: Promise) = run(p) {
        Arguments.createArray().apply { client(key, base).approve.pending().forEach { pushMap(requestMap(it)) } }
    }

    @ReactMethod fun approveApprove(key: String, base: String, req: ReadableMap, picked: String, title: String?, p: Promise) = run(p) {
        val r = request(req)
        answerMap(if (title != null) client(key, base).approve.approve(activity(), r, picked, title) else client(key, base).approve.approve(activity(), r, picked))
    }

    @ReactMethod fun approveDeny(key: String, base: String, req: ReadableMap, p: Promise) = run(p) { answerMap(client(key, base).approve.deny(request(req))) }

    @ReactMethod fun approveUpdatePushToken(key: String, base: String, token: String, p: Promise) = run(p) { client(key, base).approve.updatePushToken(token); null }

    @ReactMethod fun approveForget(key: String, base: String, p: Promise) = run(p) { client(key, base).approve.forget(); null }

    @ReactMethod fun approveOpenNative(key: String, base: String, requestId: String?, p: Promise) = run(p) { client(key, base).approve.open(activity(), requestId); null }

    @ReactMethod fun pushOpened(key: String, base: String, data: ReadableMap, action: String?, p: Promise) = run(p) { client(key, base).push.opened(strings(data), action) }

    /** Draws a SignOps push with buttons, or an activity, with the app's own icon. */
    @ReactMethod fun showNotification(key: String, base: String, data: ReadableMap, p: Promise) = run(p) {
        client(key, base)
        val ctx = reactApplicationContext
        val d = strings(data).mapNotNull { (k, v) -> v?.let { k to it } }.toMap()
        // Off the main thread: a push's image is downloaded before it is drawn.
        kotlinx.coroutines.withContext(Dispatchers.IO) { SignOps.handleMessage(ctx, d, ctx.applicationInfo.icon) }
    }

    @ReactMethod fun passkeysRegister(key: String, base: String, token: String, name: String?, p: Promise) = run(p) {
        val r = if (name != null) client(key, base).passkeys.register(activity(), token, name) else client(key, base).passkeys.register(activity(), token)
        Arguments.createMap().apply { putString("credentialId", r.credentialId); putString("userId", r.userId); putBoolean("synced", r.synced) }
    }

    @ReactMethod fun passkeysSignIn(key: String, base: String, userId: String?, p: Promise) = run(p) {
        val r = client(key, base).passkeys.signIn(activity(), userId)
        Arguments.createMap().apply { putString("signopsToken", r.signopsToken); putString("expiresAt", r.expiresAt) }
    }

    override fun invalidate() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); super.invalidate() }
}
