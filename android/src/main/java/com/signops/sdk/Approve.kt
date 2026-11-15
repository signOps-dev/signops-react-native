package com.signops

import android.content.Context
import android.content.Intent
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Approve: this phone answers "Is this you?" for its user, signing each answer with a P-256 key made in the Android
 * Keystore (StrongBox when the phone has it). The private key never leaves the phone; SignOps keeps the public key.
 *
 *     signops.approve.enroll(tokenFromYourServer, fcmToken)       // once, after your own login
 *     val waiting = signops.approve.pending()                       // when the app opens or an approve push arrives
 *     signops.approve.approve(activity, waiting[0], picked = "47")  // fingerprint, face or screen lock, then signed
 *
 * Or open the ready-made screen: signops.approve.open(activity).
 */
class Approve internal constructor(private val signops: SignOps, context: Context) {
    private val prefs = context.getSharedPreferences("signops.approve.${signops.mode}", Context.MODE_PRIVATE)
    private val alias = "signops.approve.${signops.mode}"

    data class Enrolled(val deviceId: String, val userId: String)

    /** A sign-in or action waiting for this user's answer. options holds three numbers; one of them is on the user's other screen. */
    data class Request(
        val id: String,
        val context: String,
        val city: String?,
        val browser: String?,
        val options: List<String>,
        val createdAt: String,
        val expiresAt: String,
        /** Set when the request is a payment: show it, the answer signs it. */
        val payment: Payment? = null,
    )

    /** A payment to approve (0.4.0): amount as text with two decimals, a three-letter currency, who is paid. */
    data class Payment(val amount: String, val currency: String, val payee: String) {
        /** "INR 1,49,999.00": lakh grouping for rupees, thousands otherwise. */
        val amountText: String get() {
            val (w, f) = amount.split(".").let { it[0] to it.getOrElse(1) { "00" } }
            val n = w.toBigInteger().toString()
            val grouped = if (currency == "INR") n.replace(Regex("(\\d)(?=(\\d\\d)+\\d$)"), "$1,") else n.replace(Regex("(\\d)(?=(\\d{3})+$)"), "$1,")
            return "$currency $grouped.$f"
        }
        /** "INR 1,499.00 to Sharma Stores" */
        val text: String get() = "$amountText to $payee"
    }

    /** status is approved or denied. reason is wrong_number when the user approved with a number that was not on the screen. */
    data class Answer(val id: String, val status: String, val reason: String?)

    /** True when this phone holds an Approve key and SignOps has its device id. */
    val isEnrolled: Boolean get() = deviceId != null && keyOrNull() != null

    val deviceId: String? get() = prefs.getString("device_id", null)
    val userId: String? get() = prefs.getString("user_id", null)

    /**
     * Trusts this phone for the user your server named. The token is single-use, lasts 10 minutes and comes from your
     * server: POST /v1/approve/enroll-token { user_id }. pushToken is the phone's FCM token (or, on iOS, APNs).
     * Enrolling again replaces the key. A user can have 5 trusted phones; a sixth drops the oldest.
     */
    suspend fun enroll(token: String, pushToken: String, name: String = Build.MODEL ?: "Android"): Enrolled {
        val publicKey = withContext(Dispatchers.Default) { makeKey() }
        val out = signops.post(
            "/v1/approve/devices/enroll",
            JSONObject().put("token", token).put("public_key", publicKey).put("push_token", pushToken).put("platform", "android").put("name", name.take(80)),
        )
        val enrolled = Enrolled(out.getString("device_id"), out.getString("user_id"))
        prefs.edit().putString("device_id", enrolled.deviceId).putString("user_id", enrolled.userId).apply()
        return enrolled
    }

    /** Requests waiting for this phone's user, newest first (at most 5). Call it when the app opens: some phones hold pushes. */
    suspend fun pending(): List<Request> {
        val dev = deviceId ?: throw notEnrolled()
        val ts = System.currentTimeMillis().toString()
        val out = signops.get(
            "/v1/approve/pending",
            mapOf("signops-device" to dev, "signops-timestamp" to ts, "signops-signature" to sign(Messages.pending(ts))),
        )
        return parsePending(out)
    }

    /**
     * Approves with the number the user picked, after the phone's own check (fingerprint, face or screen lock).
     * A number that is not the one on the other screen is answered as denied, reason wrong_number.
     */
    suspend fun approve(activity: FragmentActivity, request: Request, picked: String, title: String = "Approve this sign-in"): Answer {
        confirmOwner(activity, if (request.payment != null && title == "Approve this sign-in") "Approve this payment" else title, request.payment?.let { "Pay ${it.text}" } ?: request.context)
        return answer(request, "approve", picked)
    }

    /** Denies the request. No screen lock check: saying no is always allowed. */
    suspend fun deny(request: Request): Answer = answer(request, "deny", "")

    /** Call from FirebaseMessagingService.onNewToken: moves this trusted phone to its new push token. Does nothing when not enrolled. */
    suspend fun updatePushToken(pushToken: String) {
        val dev = deviceId ?: return
        if (keyOrNull() == null) return
        val ts = System.currentTimeMillis().toString()
        signops.post(
            "/v1/approve/devices/push-token",
            JSONObject().put("device_id", dev).put("push_token", pushToken).put("timestamp", ts.toLong()).put("signature", sign(Messages.pushToken(ts, pushToken))),
        )
    }

    /** Opens the ready-made screen: it fetches what is waiting and lets the user pick a number or say no. */
    fun open(context: Context, requestId: String? = null) {
        context.startActivity(ApproveActivity.intent(context, signops.key, signops.baseUrl, requestId).apply {
            if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }

    /** Removes the key and the device id from this phone, for sign-out. Your server removes the device from SignOps: POST /v1/approve/devices/:id/remove. */
    fun forget() {
        runCatching { keyStore().deleteEntry(alias) }
        prefs.edit().clear().apply()
    }

    private suspend fun answer(request: Request, decision: String, picked: String): Answer {
        val id = request.id
        val dev = deviceId ?: throw notEnrolled()
        val ts = System.currentTimeMillis().toString()
        val out = signops.post(
            "/v1/approve/$id/respond",
            JSONObject().put("device_id", dev).put("decision", decision).put("picked", picked).put("timestamp", ts.toLong())
                .put("signature", sign(Messages.respond(ts, id, decision, picked, request.payment))),
        )
        return Answer(out.getString("id"), out.getString("status"), out.optString("reason").ifEmpty { null })
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun keyOrNull(): PrivateKey? = runCatching { keyStore().getKey(alias, null) as? PrivateKey }.getOrNull()

    /** A new P-256 key under this app's alias, replacing any old one. Returns the public key as SPKI, base64url. */
    private fun makeKey(): String {
        runCatching { keyStore().deleteEntry(alias) }
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .apply { if (strongBox) setIsStrongBoxBacked(true) }
            .build()
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val pair = try {
            gen.initialize(spec(strongBox = true)); gen.generateKeyPair()
        } catch (e: StrongBoxUnavailableException) {
            gen.initialize(spec(strongBox = false)); gen.generateKeyPair()
        }
        return Messages.b64u(pair.public.encoded)
    }

    private suspend fun sign(message: String): String = withContext(Dispatchers.Default) {
        val key = keyOrNull() ?: throw notEnrolled()
        val s = Signature.getInstance("SHA256withECDSA")
        s.initSign(key)
        s.update(message.toByteArray())
        Messages.b64u(s.sign())
    }

    /** The phone's own check that its owner is holding it. Strong biometrics or the screen lock; on Android 9 and 10, any biometric or the screen lock. */
    private suspend fun confirmOwner(activity: FragmentActivity, title: String, subtitle: String) = withContext(Dispatchers.Main) {
        val allowed = if (Build.VERSION.SDK_INT >= 30) BIOMETRIC_STRONG or DEVICE_CREDENTIAL else BIOMETRIC_WEAK or DEVICE_CREDENTIAL
        when (BiometricManager.from(activity).canAuthenticate(allowed)) {
            BiometricManager.BIOMETRIC_SUCCESS -> Unit
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> throw SignOpsException(0, "no_lock", "Set a screen lock on this phone to approve sign-ins.")
            else -> throw SignOpsException(0, "no_lock", "This phone cannot check its owner right now.")
        }
        suspendCancellableCoroutine { cont ->
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { if (cont.isActive) cont.resume(Unit) }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    if (!cont.isActive) return
                    val cancelled = errorCode == BiometricPrompt.ERROR_USER_CANCELED || errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON || errorCode == BiometricPrompt.ERROR_CANCELED
                    cont.resumeWithException(SignOpsException(0, if (cancelled) "cancelled" else "auth_failed", errString.toString()))
                }
            })
            prompt.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(title).setSubtitle(subtitle.take(120)).setAllowedAuthenticators(allowed).build())
            cont.invokeOnCancellation { prompt.cancelAuthentication() }
        }
    }

    private fun notEnrolled() = SignOpsException(0, "not_enrolled", "This phone is not trusted for Approve. Call approve.enroll after your own login.")

    companion object {
        /** True for the push SignOps sends to ring the phone for an approval. Its data carries approve_id. */
        @JvmStatic fun isApprovePush(data: Map<String, String?>): Boolean = data["signops"] == "approve"

        /** The request id from an approve push, or from the extras of the notification the system showed while the app slept. */
        @JvmStatic fun requestId(data: Map<String, String?>): String? = if (isApprovePush(data)) data["approve_id"] else null
        @JvmStatic fun requestId(intent: Intent?): String? =
            intent?.extras?.takeIf { it.getString("signops") == "approve" }?.getString("approve_id")

        internal fun parsePending(out: JSONObject): List<Request> {
            val arr = out.getJSONArray("data")
            return (0 until arr.length()).map { i ->
                val r = arr.getJSONObject(i)
                val opts = r.getJSONArray("options")
                Request(
                    r.getString("id"), r.getString("context"),
                    r.optString("city").takeUnless { r.isNull("city") || it.isEmpty() },
                    r.optString("browser").takeUnless { r.isNull("browser") || it.isEmpty() },
                    (0 until opts.length()).map { opts.getString(it) }, r.getString("created_at"), r.getString("expires_at"),
                    r.optJSONObject("payment")?.let { p -> Payment(p.getString("amount"), p.getString("currency"), p.getString("payee")) },
                )
            }
        }
    }
}

/** What the phone signs, exactly as the API checks it: "<unix ms>.<what>". */
internal object Messages {
    fun pending(ts: String) = "$ts.pending"
    fun respond(ts: String, id: String, decision: String, picked: String, payment: Approve.Payment? = null) =
        "$ts.$id.$decision.$picked" + (payment?.let { ".pay:${it.currency}:${it.amount}:${it.payee}" } ?: "")
    fun pushToken(ts: String, token: String) = "$ts.token.$token"
    fun b64u(bytes: ByteArray): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
}
