# SignOps for React Native

Approve (a push to the user's trusted phone, answered with a key that never leaves it), passkeys on your own domain, and push open reporting, in a React Native app. The native work is the SignOps Android and iOS SDKs, compiled into this module: keys in the Android Keystore (StrongBox when the phone has it) and the iOS Secure Enclave, the fingerprint, face or passcode check before every approval.

```sh
npm install @signops/react-native        # not on npm yet
cd ios && pod install
```

React Native 0.73 or later, Android 9 and iOS 16 or later. Expo: a development build (`npx expo prebuild`); Expo Go cannot load native modules.

```tsx
import { ApproveScreen, SignOps } from "@signops/react-native";

const signops = new SignOps("pk_live_...");   // the publishable key; secret keys stay on your server

// After your own login. The token comes from your server: POST /v1/approve/enroll-token { user_id }.
await signops.approve.enroll(tokenFromYourServer, await messaging().getToken());

// When an approve push arrives, or the app opens: show the ready-made screen.
const id = SignOps.approveRequestId(remoteMessage.data);
<ApproveScreen signops={signops} requestId={id} colors={{ accent: "#0F766E" }} onDone={(status) => close()} />

// Or build your own screen.
const [req] = await signops.approve.pending();
await signops.approve.approve(req, "47");   // fingerprint or face first, then a signed answer
await signops.approve.deny(req);

// FCM tokens rotate.
messaging().onTokenRefresh((t) => signops.approve.updatePushToken(t));

// Count opens of any SignOps push.
messaging().onNotificationOpenedApp((m) => signops.push.opened(m.data));

// Passkeys.
await signops.passkeys.register(registrationTokenFromYourServer);
const { signopsToken } = await signops.passkeys.signIn();
```

Errors are `SignOpsError` with `code`: the API's codes, or `cancelled`, `not_enrolled`, `no_lock`, `auth_failed`, `no_passkey`, `passkey_error`, `no_activity`.

## Before it works

- iOS: `NSFaceIDUsageDescription` in Info.plist. For passkeys, the Associated Domains entry `webcredentials:<your domain>`.
- Android: `minSdkVersion 28` in `android/build.gradle`.
- Passkeys: the app added under Passkeys, Setup in the dashboard, and the `assetlinks.json` / `apple-app-site-association` files it shows hosted on your domain.

## Maintainers

`android/src/main/java/com/signops/sdk` and `ios/sdk` are copies of the native SDKs made by `node ../sync-native.mjs` (`npm run build` runs it). Edit the originals in `packages/android` and `packages/ios`.
