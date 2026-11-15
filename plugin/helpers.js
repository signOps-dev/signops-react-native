// The Expo config plugin's changes, as plain functions on plain objects, so they are tested without Expo (build/plan-11-cli-and-expo.md).
const fs = require("fs");
const path = require("path");

/** iOS entitlements: push on. EAS changes development to production for store builds. */
function entitlements(ent, mode) {
  return { ...ent, "aps-environment": ent["aps-environment"] || mode || "development" };
}

/** iOS Info.plist: wake for pushes in the background (silent pushes, Live Activity updates). */
function infoPlist(plist) {
  const modes = Array.isArray(plist.UIBackgroundModes) ? plist.UIBackgroundModes : [];
  return modes.includes("remote-notification") ? plist : { ...plist, UIBackgroundModes: [...modes, "remote-notification"] };
}

/** Android: ask for the notification permission (Android 13 and later need it). */
function androidPermissions(list) {
  const want = "android.permission.POST_NOTIFICATIONS";
  return (list || []).includes(want) ? list : [...(list || []), want];
}

/** The Firebase file for Android: kept if set, else ./google-services.json when the project has one. */
function googleServicesFile(config, projectRoot) {
  const android = config.android || {};
  if (android.googleServicesFile) return config;
  if (!fs.existsSync(path.join(projectRoot, "google-services.json"))) return config;
  return { ...config, android: { ...android, googleServicesFile: "./google-services.json" } };
}

module.exports = { entitlements, infoPlist, androidPermissions, googleServicesFile };
