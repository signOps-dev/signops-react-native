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
import React, { useEffect, useRef, useState } from "react";
import { NativeModules, Platform, Pressable, StyleSheet, Text, View } from "react-native";

const LINK_ERROR =
  "The SignOps native module is not linked. Rebuild the app after installing @signops/react-native (iOS: cd ios && pod install). Expo Go cannot load it: use a development build.";

type Native = {
  approveStatus(key: string, base: string): Promise<{ enrolled: boolean; deviceId: string | null; userId: string | null }>;
  approveEnroll(key: string, base: string, token: string, pushToken: string, name: string | null): Promise<Enrolled>;
  approvePending(key: string, base: string): Promise<ApproveRequest[]>;
  approveApprove(key: string, base: string, req: ApproveRequest, picked: string, title: string | null): Promise<ApproveAnswer>;
  approveDeny(key: string, base: string, req: ApproveRequest): Promise<ApproveAnswer>;
  approveUpdatePushToken(key: string, base: string, token: string): Promise<null>;
  approveForget(key: string, base: string): Promise<null>;
  pushOpened(key: string, base: string, data: Record<string, unknown>, action: string | null): Promise<boolean>;
  passkeysRegister(key: string, base: string, token: string, name: string | null): Promise<PasskeyRegistered>;
  passkeysSignIn(key: string, base: string, userId: string | null): Promise<PasskeySignedIn>;
  /** Android only: draws a SignOps push with buttons, or an activity. */
  showNotification?(key: string, base: string, data: Record<string, unknown>): Promise<boolean>;
};

const native: Native =
  NativeModules.SignOpsRN ??
  new Proxy({} as Native, {
    get() {
      throw new Error(LINK_ERROR);
    },
  });

export type Enrolled = { deviceId: string; userId: string };
/** A sign-in or action waiting for this user's answer. options holds three numbers; one of them is on the user's other screen. */
/** A payment to approve (0.4.0): the phone shows it and signs it with the answer. */
export type ApprovePayment = { amount: string; currency: string; payee: string };
export type ApproveRequest = { id: string; context: string; city: string | null; browser: string | null; options: string[]; createdAt: string; expiresAt: string; payment?: ApprovePayment | null };
/** "INR 1,499.00" */
export const paymentAmount = (p: ApprovePayment) => {
  const [w, f = "00"] = p.amount.split(".");
  // Lakh grouping for rupees (1,49,999), thousands otherwise.
  return `${p.currency} ${p.currency === "INR" ? w.replace(/(\d)(?=(\d\d)+\d$)/g, "$1,") : w.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${f}`;
};
/** status is approved or denied. reason is wrong_number when the user approved with a number that was not on the screen. */
export type ApproveAnswer = { id: string; status: "approved" | "denied"; reason: string | null };
export type PasskeyRegistered = { credentialId: string; userId: string; synced: boolean };
export type PasskeySignedIn = { signopsToken: string; expiresAt: string };

/**
 * An error from SignOps or the phone. code is the API's code (expired, already_done, invalid_key, ...) or one of
 * cancelled, not_enrolled, no_lock, auth_failed, no_passkey, passkey_error, no_activity.
 */
export class SignOpsError extends Error {
  constructor(readonly code: string, message: string, readonly status = 0) {
    super(message);
    this.name = "SignOpsError";
  }
}

async function call<T>(p: Promise<T>): Promise<T> {
  try {
    return await p;
  } catch (e) {
    const err = e as { code?: string; message?: string; userInfo?: { status?: number } };
    throw new SignOpsError(err.code ?? "error", err.message ?? String(e), err.userInfo?.status ?? 0);
  }
}

export class SignOps {
  readonly approve: Approve;
  readonly push: Push;
  readonly passkeys: Passkeys;
  readonly inbox: Inbox;
  readonly activities: Activities;

  constructor(readonly key: string, readonly baseUrl = "https://api.signops.dev") {
    if (!key.startsWith("pk_live_") && !key.startsWith("pk_test_"))
      throw new Error("Use the app's publishable key (pk_live_ or pk_test_). A secret key must never ship in an app.");
    this.approve = new Approve(this);
    this.push = new Push(this);
    this.passkeys = new Passkeys(this);
    this.inbox = new Inbox(this);
    this.activities = new Activities(this);
  }

  /** A call to the API with the publishable key, from JavaScript (inbox and activity tokens need no native code). */
  async request<T>(method: "GET" | "POST" | "DELETE", path: string, body?: unknown, headers: Record<string, string> = {}): Promise<T> {
    const res = await fetch(this.baseUrl.replace(/\/$/, "") + path, {
      method, headers: { authorization: `Bearer ${this.key}`, ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const j = (await res.json().catch(() => ({}))) as { error?: { code?: string; message?: string } };
    if (!res.ok) throw new SignOpsError(j.error?.code ?? "error", j.error?.message ?? `SignOps answered ${res.status}`, res.status);
    return j as T;
  }

  /** The approve request id in a push's data, or null when it is not an approve push. */
  static approveRequestId(data: Record<string, unknown> | undefined | null): string | null {
    return data?.signops === "approve" && typeof data.approve_id === "string" ? data.approve_id : null;
  }

  /** The SignOps message id in a push's data, or null for a push that did not come through SignOps. */
  static messageId(data: Record<string, unknown> | undefined | null): string | null {
    const id = data?.signops_id;
    return typeof id === "string" && id.startsWith("msg_") ? id : null;
  }
}

export class Approve {
  constructor(private s: SignOps) {}

  /** Whether this phone holds an Approve key, and for which user. */
  status() {
    return call(native.approveStatus(this.s.key, this.s.baseUrl));
  }

  /**
   * Trusts this phone for the user your server named. The token is single-use and lasts 10 minutes: your server makes it
   * with POST /v1/approve/enroll-token { user_id }. pushToken is what your server would register for this phone: the
   * FCM token, or on iOS the APNs token as hex when the app sends straight to APNs.
   */
  enroll(token: string, pushToken: string, name?: string) {
    return call(native.approveEnroll(this.s.key, this.s.baseUrl, token, pushToken, name ?? null));
  }

  /** Requests waiting for this phone's user, newest first (at most 5). Call it when the app opens as well as on the push. */
  pending() {
    return call(native.approvePending(this.s.key, this.s.baseUrl));
  }

  /** Approves with the number the user picked, after the fingerprint, face or screen lock check. */
  approve(request: ApproveRequest, picked: string, title?: string) {
    return call(native.approveApprove(this.s.key, this.s.baseUrl, request, picked, title ?? null));
  }

  /** Denies the request. No fingerprint needed: saying no is always allowed. */
  deny(request: ApproveRequest) {
    return call(native.approveDeny(this.s.key, this.s.baseUrl, request));
  }

  /** Call when the push token changes (messaging().onTokenRefresh). Does nothing when the phone is not enrolled. */
  updatePushToken(pushToken: string) {
    return call(native.approveUpdatePushToken(this.s.key, this.s.baseUrl, pushToken));
  }

  /** Removes the key from this phone, for sign-out. Your server removes the device: POST /v1/approve/devices/:id/remove. */
  forget() {
    return call(native.approveForget(this.s.key, this.s.baseUrl));
  }
}

export class Push {
  constructor(private s: SignOps) {}

  /**
   * Reports that the user opened a push (or tapped one of its buttons: action is the button's id). Returns false, without
   * a call, for a push that did not come through SignOps. data is RemoteMessage.data on Android, or the notification's
   * data / userInfo on iOS.
   */
  async opened(data: Record<string, unknown> | undefined | null, action?: string): Promise<boolean> {
    if (!SignOps.messageId(data)) return false;
    return call(native.pushOpened(this.s.key, this.s.baseUrl, data as Record<string, unknown>, action ?? null));
  }

  /**
   * Android: draws a SignOps push with buttons (it arrives as data only) or an activity, with the app's icon. Call it from
   * messaging().setBackgroundMessageHandler and onMessage. Returns false for anything else, and always on iOS, where the
   * system draws pushes and buttons come from the category in ios_category.
   */
  async show(data: Record<string, unknown> | undefined | null): Promise<boolean> {
    if (Platform.OS !== "android" || !data || !native.showNotification) return false;
    return call(native.showNotification(this.s.key, this.s.baseUrl, data));
  }
}

export type InboxItem = { id: string; title: string | null; body: string | null; link: string | null; image: string | null; data: Record<string, string> | null; push_id: string | null; created_at: string; read: boolean };

/** The user's notification inbox (Starter and Pro), read with the token your server makes (POST /v1/inbox/token). */
export class Inbox {
  constructor(private s: SignOps) {}
  list(token: string, o: { limit?: number; before?: string } = {}) {
    const qs = [o.limit ? `limit=${o.limit}` : "", o.before ? `before=${encodeURIComponent(o.before)}` : ""].filter(Boolean).join("&");
    return this.s.request<{ data: InboxItem[]; unread: number; next: string | null }>("GET", `/v1/inbox${qs ? `?${qs}` : ""}`, undefined, { "signops-inbox-token": token });
  }
  read(token: string, ids: string[]) { return this.s.request<{ read: number }>("POST", "/v1/inbox/read", { ids }, { "signops-inbox-token": token }); }
  readAll(token: string) { return this.s.request<{ read: number }>("POST", "/v1/inbox/read", { all: true }, { "signops-inbox-token": token }); }
  remove(token: string, id: string) { return this.s.request<{ id: string; deleted: true }>("DELETE", `/v1/inbox/${encodeURIComponent(id)}`, undefined, { "signops-inbox-token": token }); }
}

/**
 * Live Activities and ongoing notifications (Starter and Pro). iOS: start the Live Activity in your Swift code with
 * ActivityKit and pass its push token here as hex. Android: call push.show(data) from your background message handler.
 */
export class Activities {
  constructor(private s: SignOps) {}
  sendToken(ref: string, pushTokenHex: string) { return this.s.request<{ ref: string; ios: true }>("POST", `/v1/activities/${encodeURIComponent(ref)}/token`, { push_token: pushTokenHex }); }
}

export class Passkeys {
  constructor(private s: SignOps) {}

  /** Makes a passkey for the user the token was made for (your server: POST /v1/passkeys/registration-token). */
  register(token: string, name?: string) {
    return call(native.passkeysRegister(this.s.key, this.s.baseUrl, token, name ?? null));
  }

  /** Signs in with a passkey. Send signopsToken to your server, which checks it with POST /v1/passkeys/verify. */
  signIn(opts: { userId?: string } = {}) {
    return call(native.passkeysSignIn(this.s.key, this.s.baseUrl, opts.userId ?? null));
  }
}

export type ApproveColors = { accent?: string; onAccent?: string; background?: string; text?: string; muted?: string };
export type ApproveStatus = "approved" | "denied" | "expired" | "none";

/**
 * The ready-made approve screen: what is being approved, where from, three numbers and "No, it was not me".
 * Render it full screen (a modal or a route) when an approve push arrives or the app opens with something pending.
 */
export function ApproveScreen(props: { signops: SignOps; requestId?: string | null; colors?: ApproveColors; onDone?: (status: ApproveStatus) => void }) {
  const c = { accent: "#1F6FEB", onAccent: "#FFFFFF", background: "#FFFFFF", text: "#111111", muted: "#5F6368", ...props.colors };
  const [req, setReq] = useState<ApproveRequest | null>(null);
  const [note, setNote] = useState("Checking for requests");
  const [busy, setBusy] = useState(false);
  const [left, setLeft] = useState(120);
  const finished = useRef(false);

  const done = (status: ApproveStatus, text: string) => {
    if (finished.current) return;
    finished.current = true;
    setReq(null);
    setBusy(false);
    setNote(text);
    setTimeout(() => props.onDone?.(status), status === "approved" ? 900 : 2200);
  };

  useEffect(() => {
    props.signops.approve
      .pending()
      .then((list) => {
        const r = list.find((x) => x.id === props.requestId) ?? list[0];
        if (r) setReq(r);
        else done("none", props.requestId ? "This request was already answered or has expired." : "Nothing is waiting for you.");
      })
      .catch((e: SignOpsError) => done("none", e.message));
  }, []);

  useEffect(() => {
    if (!req) return;
    const ends = Date.parse(req.expiresAt) || Date.now() + 120_000;
    const tick = () => {
      const s = Math.max(0, Math.floor((ends - Date.now()) / 1000));
      setLeft(s);
      if (s === 0) done("expired", "This request expired.");
    };
    tick();
    const t = setInterval(tick, 1000);
    return () => clearInterval(t);
  }, [req?.id]);

  const pick = async (n: string) => {
    if (!req) return;
    setBusy(true);
    try {
      const a = await props.signops.approve.approve(req, n);
      done(a.status, a.status === "approved" ? "Approved" : "Denied: that number was not the one on the other screen.");
    } catch (e) {
      const err = e as SignOpsError;
      if (err.code === "cancelled") setBusy(false);
      else done(err.code === "expired" ? "expired" : "none", err.message);
    }
  };

  const deny = async () => {
    if (!req) return;
    setBusy(true);
    try {
      await props.signops.approve.deny(req);
      done("denied", "Denied. Change your password if you did not try to sign in.");
    } catch (e) {
      done("none", (e as SignOpsError).message);
    }
  };

  if (!req) {
    return (
      <View style={[st.root, { backgroundColor: c.background }]}>
        <Text style={[st.note, { color: c.muted }]}>{note}</Text>
      </View>
    );
  }
  const place = [req.browser, req.city].filter(Boolean).join(", ");
  return (
    <View style={[st.root, { backgroundColor: c.background, opacity: busy ? 0.6 : 1 }]} pointerEvents={busy ? "none" : "auto"}>
      <Text style={[st.h, { color: c.text }]}>{req.payment ? "Approve this payment?" : "Is this you?"}</Text>
      {req.payment ? <>
        <Text style={[st.amount, { color: c.text }]}>{paymentAmount(req.payment)}</Text>
        <Text style={[st.ctx, { color: c.text, marginTop: 4 }]}>{`to ${req.payment.payee}`}</Text>
      </> : <Text style={[st.ctx, { color: c.text }]}>{req.context}</Text>}
      {place ? <Text style={[st.small, { color: c.muted }]}>{place}</Text> : null}
      <Text style={[st.small, { color: c.muted }]}>{`Expires in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`}</Text>
      <Text style={[st.ask, { color: c.text }]}>Tap the number shown on the other screen</Text>
      <View style={st.row}>
        {req.options.map((n) => (
          <Pressable key={n} accessibilityRole="button" accessibilityLabel={`Number ${n}`} onPress={() => pick(n)} style={[st.num, { backgroundColor: c.accent }]}>
            <Text style={[st.numText, { color: c.onAccent }]}>{n}</Text>
          </Pressable>
        ))}
      </View>
      <Pressable accessibilityRole="button" onPress={deny} style={[st.no, { borderColor: c.muted }]}>
        <Text style={[st.noText, { color: c.text }]}>No, it was not me</Text>
      </Pressable>
    </View>
  );
}

const st = StyleSheet.create({
  root: { flex: 1, paddingHorizontal: 24, paddingTop: Platform.OS === "ios" ? 64 : 48 },
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
