"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.Passkeys = exports.Activities = exports.Inbox = exports.Push = exports.Approve = exports.SignOps = exports.SignOpsError = exports.paymentAmount = void 0;
exports.ApproveScreen = ApproveScreen;
// SignOps in a React Native app, with the app's publishable key (pk_live_ or pk_test_). Secret keys stay on your server.
//
//   const signops = new SignOps("pk_live_...");
//   await signops.approve.enroll(tokenFromYourServer, fcmOrApnsToken);   // once, after your own login
//   const waiting = await signops.approve.pending();                      // when the app opens or an approve push arrives
//   <ApproveScreen signops={signops} onDone={(status) => ...} />          // or the ready-made screen
//   await signops.push.opened(remoteMessage.data);                        // count an open
//
// The native work (keys in the Android Keystore and iOS Secure Enclave, the fingerprint or Face ID check, passkeys) is the
// SignOps Android and iOS SDKs, compiled into this module.
const react_1 = __importStar(require("react"));
const react_native_1 = require("react-native");
const LINK_ERROR = "The SignOps native module is not linked. Rebuild the app after installing @signops/react-native (iOS: cd ios && pod install). Expo Go cannot load it: use a development build.";
const native = react_native_1.NativeModules.SignOpsRN ??
    new Proxy({}, {
        get() {
            throw new Error(LINK_ERROR);
        },
    });
/** "INR 1,499.00" */
const paymentAmount = (p) => {
    const [w, f = "00"] = p.amount.split(".");
    // Lakh grouping for rupees (1,49,999), thousands otherwise.
    return `${p.currency} ${p.currency === "INR" ? w.replace(/(\d)(?=(\d\d)+\d$)/g, "$1,") : w.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${f}`;
};
exports.paymentAmount = paymentAmount;
/**
 * An error from SignOps or the phone. code is the API's code (expired, already_done, invalid_key, ...) or one of
 * cancelled, not_enrolled, no_lock, auth_failed, no_passkey, passkey_error, no_activity.
 */
class SignOpsError extends Error {
    constructor(code, message, status = 0) {
        super(message);
        this.code = code;
        this.status = status;
        this.name = "SignOpsError";
    }
}
exports.SignOpsError = SignOpsError;
async function call(p) {
    try {
        return await p;
    }
    catch (e) {
        const err = e;
        throw new SignOpsError(err.code ?? "error", err.message ?? String(e), err.userInfo?.status ?? 0);
    }
}
class SignOps {
    constructor(key, baseUrl = "https://api.signops.dev") {
        this.key = key;
        this.baseUrl = baseUrl;
        if (!key.startsWith("pk_live_") && !key.startsWith("pk_test_"))
            throw new Error("Use the app's publishable key (pk_live_ or pk_test_). A secret key must never ship in an app.");
        this.approve = new Approve(this);
        this.push = new Push(this);
        this.passkeys = new Passkeys(this);
        this.inbox = new Inbox(this);
        this.activities = new Activities(this);
    }
    /** A call to the API with the publishable key, from JavaScript (inbox and activity tokens need no native code). */
    async request(method, path, body, headers = {}) {
        const res = await fetch(this.baseUrl.replace(/\/$/, "") + path, {
            method, headers: { authorization: `Bearer ${this.key}`, ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
            body: body !== undefined ? JSON.stringify(body) : undefined,
        });
        const j = (await res.json().catch(() => ({})));
        if (!res.ok)
            throw new SignOpsError(j.error?.code ?? "error", j.error?.message ?? `SignOps answered ${res.status}`, res.status);
        return j;
    }
    /** The approve request id in a push's data, or null when it is not an approve push. */
    static approveRequestId(data) {
        return data?.signops === "approve" && typeof data.approve_id === "string" ? data.approve_id : null;
    }
    /** The SignOps message id in a push's data, or null for a push that did not come through SignOps. */
    static messageId(data) {
        const id = data?.signops_id;
        return typeof id === "string" && id.startsWith("msg_") ? id : null;
    }
}
exports.SignOps = SignOps;
class Approve {
    constructor(s) {
        this.s = s;
    }
    /** Whether this phone holds an Approve key, and for which user. */
    status() {
        return call(native.approveStatus(this.s.key, this.s.baseUrl));
    }
    /**
     * Trusts this phone for the user your server named. The token is single-use and lasts 10 minutes: your server makes it
     * with POST /v1/approve/enroll-token { user_id }. pushToken is what your server would register for this phone: the
     * FCM token, or on iOS the APNs token as hex when the app sends straight to APNs.
     */
    enroll(token, pushToken, name) {
        return call(native.approveEnroll(this.s.key, this.s.baseUrl, token, pushToken, name ?? null));
    }
    /** Requests waiting for this phone's user, newest first (at most 5). Call it when the app opens as well as on the push. */
    pending() {
        return call(native.approvePending(this.s.key, this.s.baseUrl));
    }
    /** Approves with the number the user picked, after the fingerprint, face or screen lock check. */
    approve(request, picked, title) {
        return call(native.approveApprove(this.s.key, this.s.baseUrl, request, picked, title ?? null));
    }
    /** Denies the request. No fingerprint needed: saying no is always allowed. */
    deny(request) {
        return call(native.approveDeny(this.s.key, this.s.baseUrl, request));
    }
    /** Call when the push token changes (messaging().onTokenRefresh). Does nothing when the phone is not enrolled. */
    updatePushToken(pushToken) {
        return call(native.approveUpdatePushToken(this.s.key, this.s.baseUrl, pushToken));
    }
    /** Removes the key from this phone, for sign-out. Your server removes the device: POST /v1/approve/devices/:id/remove. */
    forget() {
        return call(native.approveForget(this.s.key, this.s.baseUrl));
    }
}
exports.Approve = Approve;
class Push {
    constructor(s) {
        this.s = s;
    }
    /**
     * Reports that the user opened a push (or tapped one of its buttons: action is the button's id). Returns false, without
     * a call, for a push that did not come through SignOps. data is RemoteMessage.data on Android, or the notification's
     * data / userInfo on iOS.
     */
    async opened(data, action) {
        if (!SignOps.messageId(data))
            return false;
        return call(native.pushOpened(this.s.key, this.s.baseUrl, data, action ?? null));
    }
    /**
     * Android: draws a SignOps push with buttons (it arrives as data only) or an activity, with the app's icon. Call it from
     * messaging().setBackgroundMessageHandler and onMessage. Returns false for anything else, and always on iOS, where the
     * system draws pushes and buttons come from the category in ios_category.
     */
    async show(data) {
        if (react_native_1.Platform.OS !== "android" || !data || !native.showNotification)
            return false;
        return call(native.showNotification(this.s.key, this.s.baseUrl, data));
    }
}
exports.Push = Push;
/** The user's notification inbox (Starter and Pro), read with the token your server makes (POST /v1/inbox/token). */
class Inbox {
    constructor(s) {
        this.s = s;
    }
    list(token, o = {}) {
        const qs = [o.limit ? `limit=${o.limit}` : "", o.before ? `before=${encodeURIComponent(o.before)}` : ""].filter(Boolean).join("&");
        return this.s.request("GET", `/v1/inbox${qs ? `?${qs}` : ""}`, undefined, { "signops-inbox-token": token });
    }
    read(token, ids) { return this.s.request("POST", "/v1/inbox/read", { ids }, { "signops-inbox-token": token }); }
    readAll(token) { return this.s.request("POST", "/v1/inbox/read", { all: true }, { "signops-inbox-token": token }); }
    remove(token, id) { return this.s.request("DELETE", `/v1/inbox/${encodeURIComponent(id)}`, undefined, { "signops-inbox-token": token }); }
}
exports.Inbox = Inbox;
/**
 * Live Activities and ongoing notifications (Starter and Pro). iOS: start the Live Activity in your Swift code with
 * ActivityKit and pass its push token here as hex. Android: call push.show(data) from your background message handler.
 */
class Activities {
    constructor(s) {
        this.s = s;
    }
    sendToken(ref, pushTokenHex) { return this.s.request("POST", `/v1/activities/${encodeURIComponent(ref)}/token`, { push_token: pushTokenHex }); }
}
exports.Activities = Activities;
class Passkeys {
    constructor(s) {
        this.s = s;
    }
    /** Makes a passkey for the user the token was made for (your server: POST /v1/passkeys/registration-token). */
    register(token, name) {
        return call(native.passkeysRegister(this.s.key, this.s.baseUrl, token, name ?? null));
    }
    /** Signs in with a passkey. Send signopsToken to your server, which checks it with POST /v1/passkeys/verify. */
    signIn(opts = {}) {
        return call(native.passkeysSignIn(this.s.key, this.s.baseUrl, opts.userId ?? null));
    }
}
exports.Passkeys = Passkeys;
/**
 * The ready-made approve screen: what is being approved, where from, three numbers and "No, it was not me".
 * Render it full screen (a modal or a route) when an approve push arrives or the app opens with something pending.
 */
function ApproveScreen(props) {
    const c = { accent: "#1F6FEB", onAccent: "#FFFFFF", background: "#FFFFFF", text: "#111111", muted: "#5F6368", ...props.colors };
    const [req, setReq] = (0, react_1.useState)(null);
    const [note, setNote] = (0, react_1.useState)("Checking for requests");
    const [busy, setBusy] = (0, react_1.useState)(false);
    const [left, setLeft] = (0, react_1.useState)(120);
    const finished = (0, react_1.useRef)(false);
    const done = (status, text) => {
        if (finished.current)
            return;
        finished.current = true;
        setReq(null);
        setBusy(false);
        setNote(text);
        setTimeout(() => props.onDone?.(status), status === "approved" ? 900 : 2200);
    };
    (0, react_1.useEffect)(() => {
        props.signops.approve
            .pending()
            .then((list) => {
            const r = list.find((x) => x.id === props.requestId) ?? list[0];
            if (r)
                setReq(r);
            else
                done("none", props.requestId ? "This request was already answered or has expired." : "Nothing is waiting for you.");
        })
            .catch((e) => done("none", e.message));
    }, []);
    (0, react_1.useEffect)(() => {
        if (!req)
            return;
        const ends = Date.parse(req.expiresAt) || Date.now() + 120000;
        const tick = () => {
            const s = Math.max(0, Math.floor((ends - Date.now()) / 1000));
            setLeft(s);
            if (s === 0)
                done("expired", "This request expired.");
        };
        tick();
        const t = setInterval(tick, 1000);
        return () => clearInterval(t);
    }, [req?.id]);
    const pick = async (n) => {
        if (!req)
            return;
        setBusy(true);
        try {
            const a = await props.signops.approve.approve(req, n);
            done(a.status, a.status === "approved" ? "Approved" : "Denied: that number was not the one on the other screen.");
        }
        catch (e) {
            const err = e;
            if (err.code === "cancelled")
                setBusy(false);
            else
                done(err.code === "expired" ? "expired" : "none", err.message);
        }
    };
    const deny = async () => {
        if (!req)
            return;
        setBusy(true);
        try {
            await props.signops.approve.deny(req);
            done("denied", "Denied. Change your password if you did not try to sign in.");
        }
        catch (e) {
            done("none", e.message);
        }
    };
    if (!req) {
        return (react_1.default.createElement(react_native_1.View, { style: [st.root, { backgroundColor: c.background }] },
            react_1.default.createElement(react_native_1.Text, { style: [st.note, { color: c.muted }] }, note)));
    }
    const place = [req.browser, req.city].filter(Boolean).join(", ");
    return (react_1.default.createElement(react_native_1.View, { style: [st.root, { backgroundColor: c.background, opacity: busy ? 0.6 : 1 }], pointerEvents: busy ? "none" : "auto" },
        react_1.default.createElement(react_native_1.Text, { style: [st.h, { color: c.text }] }, req.payment ? "Approve this payment?" : "Is this you?"),
        req.payment ? react_1.default.createElement(react_1.default.Fragment, null,
            react_1.default.createElement(react_native_1.Text, { style: [st.amount, { color: c.text }] }, (0, exports.paymentAmount)(req.payment)),
            react_1.default.createElement(react_native_1.Text, { style: [st.ctx, { color: c.text, marginTop: 4 }] }, `to ${req.payment.payee}`)) : react_1.default.createElement(react_native_1.Text, { style: [st.ctx, { color: c.text }] }, req.context),
        place ? react_1.default.createElement(react_native_1.Text, { style: [st.small, { color: c.muted }] }, place) : null,
        react_1.default.createElement(react_native_1.Text, { style: [st.small, { color: c.muted }] }, `Expires in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`),
        react_1.default.createElement(react_native_1.Text, { style: [st.ask, { color: c.text }] }, "Tap the number shown on the other screen"),
        react_1.default.createElement(react_native_1.View, { style: st.row }, req.options.map((n) => (react_1.default.createElement(react_native_1.Pressable, { key: n, accessibilityRole: "button", accessibilityLabel: `Number ${n}`, onPress: () => pick(n), style: [st.num, { backgroundColor: c.accent }] },
            react_1.default.createElement(react_native_1.Text, { style: [st.numText, { color: c.onAccent }] }, n))))),
        react_1.default.createElement(react_native_1.Pressable, { accessibilityRole: "button", onPress: deny, style: [st.no, { borderColor: c.muted }] },
            react_1.default.createElement(react_native_1.Text, { style: [st.noText, { color: c.text }] }, "No, it was not me"))));
}
const st = react_native_1.StyleSheet.create({
    root: { flex: 1, paddingHorizontal: 24, paddingTop: react_native_1.Platform.OS === "ios" ? 64 : 48 },
    note: { fontSize: 17 },
    h: { fontSize: 28, fontWeight: "700" },
    ctx: { fontSize: 20, marginTop: 16 },
    amount: { fontSize: 36, fontWeight: "700", marginTop: 16 },
    small: { fontSize: 15, marginTop: 6 },
    ask: { fontSize: 16, marginTop: 40 },
    row: { flexDirection: "row", gap: 12, marginTop: 14 },
    num: { flex: 1, height: 76, borderRadius: 14, alignItems: "center", justifyContent: "center" },
    numText: { fontSize: 30, fontWeight: "700" },
    no: { height: 56, borderRadius: 14, borderWidth: 1, alignItems: "center", justifyContent: "center", marginTop: 28 },
    noText: { fontSize: 17 },
});
