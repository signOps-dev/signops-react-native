import React from "react";
export type Enrolled = {
    deviceId: string;
    userId: string;
};
/** A sign-in or action waiting for this user's answer. options holds three numbers; one of them is on the user's other screen. */
/** A payment to approve (0.4.0): the phone shows it and signs it with the answer. */
export type ApprovePayment = {
    amount: string;
    currency: string;
    payee: string;
};
export type ApproveRequest = {
    id: string;
    context: string;
    city: string | null;
    browser: string | null;
    options: string[];
    createdAt: string;
    expiresAt: string;
    payment?: ApprovePayment | null;
};
/** "INR 1,499.00" */
export declare const paymentAmount: (p: ApprovePayment) => string;
/** status is approved or denied. reason is wrong_number when the user approved with a number that was not on the screen. */
export type ApproveAnswer = {
    id: string;
    status: "approved" | "denied";
    reason: string | null;
};
export type PasskeyRegistered = {
    credentialId: string;
    userId: string;
    synced: boolean;
};
export type PasskeySignedIn = {
    signopsToken: string;
    expiresAt: string;
};
/**
 * An error from SignOps or the phone. code is the API's code (expired, already_done, invalid_key, ...) or one of
 * cancelled, not_enrolled, no_lock, auth_failed, no_passkey, passkey_error, no_activity.
 */
export declare class SignOpsError extends Error {
    readonly code: string;
    readonly status: number;
    constructor(code: string, message: string, status?: number);
}
export declare class SignOps {
    readonly key: string;
    readonly baseUrl: string;
    readonly approve: Approve;
    readonly push: Push;
    readonly passkeys: Passkeys;
    readonly inbox: Inbox;
    readonly activities: Activities;
    constructor(key: string, baseUrl?: string);
    /** A call to the API with the publishable key, from JavaScript (inbox and activity tokens need no native code). */
    request<T>(method: "GET" | "POST" | "DELETE", path: string, body?: unknown, headers?: Record<string, string>): Promise<T>;
    /** The approve request id in a push's data, or null when it is not an approve push. */
    static approveRequestId(data: Record<string, unknown> | undefined | null): string | null;
    /** The SignOps message id in a push's data, or null for a push that did not come through SignOps. */
    static messageId(data: Record<string, unknown> | undefined | null): string | null;
}
export declare class Approve {
    private s;
    constructor(s: SignOps);
    /** Whether this phone holds an Approve key, and for which user. */
    status(): Promise<{
        enrolled: boolean;
        deviceId: string | null;
        userId: string | null;
    }>;
    /**
     * Trusts this phone for the user your server named. The token is single-use and lasts 10 minutes: your server makes it
     * with POST /v1/approve/enroll-token { user_id }. pushToken is what your server would register for this phone: the
     * FCM token, or on iOS the APNs token as hex when the app sends straight to APNs.
     */
    enroll(token: string, pushToken: string, name?: string): Promise<Enrolled>;
    /** Requests waiting for this phone's user, newest first (at most 5). Call it when the app opens as well as on the push. */
    pending(): Promise<ApproveRequest[]>;
    /** Approves with the number the user picked, after the fingerprint, face or screen lock check. */
    approve(request: ApproveRequest, picked: string, title?: string): Promise<ApproveAnswer>;
    /** Denies the request. No fingerprint needed: saying no is always allowed. */
    deny(request: ApproveRequest): Promise<ApproveAnswer>;
    /** Call when the push token changes (messaging().onTokenRefresh). Does nothing when the phone is not enrolled. */
    updatePushToken(pushToken: string): Promise<null>;
    /** Removes the key from this phone, for sign-out. Your server removes the device: POST /v1/approve/devices/:id/remove. */
    forget(): Promise<null>;
}
export declare class Push {
    private s;
    constructor(s: SignOps);
    /**
     * Reports that the user opened a push (or tapped one of its buttons: action is the button's id). Returns false, without
     * a call, for a push that did not come through SignOps. data is RemoteMessage.data on Android, or the notification's
     * data / userInfo on iOS.
     */
    opened(data: Record<string, unknown> | undefined | null, action?: string): Promise<boolean>;
    /**
     * Android: draws a SignOps push with buttons (it arrives as data only) or an activity, with the app's icon. Call it from
     * messaging().setBackgroundMessageHandler and onMessage. Returns false for anything else, and always on iOS, where the
     * system draws pushes and buttons come from the category in ios_category.
     */
    show(data: Record<string, unknown> | undefined | null): Promise<boolean>;
}
export type InboxItem = {
    id: string;
    title: string | null;
    body: string | null;
    link: string | null;
    image: string | null;
    data: Record<string, string> | null;
    push_id: string | null;
    created_at: string;
    read: boolean;
};
/** The user's notification inbox (Starter and Pro), read with the token your server makes (POST /v1/inbox/token). */
export declare class Inbox {
    private s;
    constructor(s: SignOps);
    list(token: string, o?: {
        limit?: number;
        before?: string;
    }): Promise<{
        data: InboxItem[];
        unread: number;
        next: string | null;
    }>;
    read(token: string, ids: string[]): Promise<{
        read: number;
    }>;
    readAll(token: string): Promise<{
        read: number;
    }>;
    remove(token: string, id: string): Promise<{
        id: string;
        deleted: true;
    }>;
}
/**
 * Live Activities and ongoing notifications (Starter and Pro). iOS: start the Live Activity in your Swift code with
 * ActivityKit and pass its push token here as hex. Android: call push.show(data) from your background message handler.
 */
export declare class Activities {
    private s;
    constructor(s: SignOps);
    sendToken(ref: string, pushTokenHex: string): Promise<{
        ref: string;
        ios: true;
    }>;
}
export declare class Passkeys {
    private s;
    constructor(s: SignOps);
    /** Makes a passkey for the user the token was made for (your server: POST /v1/passkeys/registration-token). */
    register(token: string, name?: string): Promise<PasskeyRegistered>;
    /** Signs in with a passkey. Send signopsToken to your server, which checks it with POST /v1/passkeys/verify. */
    signIn(opts?: {
        userId?: string;
    }): Promise<PasskeySignedIn>;
}
export type ApproveColors = {
    accent?: string;
    onAccent?: string;
    background?: string;
    text?: string;
    muted?: string;
};
export type ApproveStatus = "approved" | "denied" | "expired" | "none";
/**
 * The ready-made approve screen: what is being approved, where from, three numbers and "No, it was not me".
 * Render it full screen (a modal or a route) when an approve push arrives or the app opens with something pending.
 */
export declare function ApproveScreen(props: {
    signops: SignOps;
    requestId?: string | null;
    colors?: ApproveColors;
    onDone?: (status: ApproveStatus) => void;
}): React.JSX.Element;
