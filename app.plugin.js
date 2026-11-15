// Expo config plugin: "plugins": ["@signops/react-native"] in app.json. Turns on push for iOS and Android at prebuild.
// Options: { "apsEnvironment": "production" } to start from production instead of development.
const { withEntitlementsPlist, withInfoPlist, AndroidConfig } = require("@expo/config-plugins");
const { entitlements, infoPlist, androidPermissions, googleServicesFile } = require("./plugin/helpers");

module.exports = function withSignOps(config, options = {}) {
  config = googleServicesFile(config, config._internal?.projectRoot || process.cwd());
  config = withEntitlementsPlist(config, (c) => { c.modResults = entitlements(c.modResults, options.apsEnvironment); return c; });
  config = withInfoPlist(config, (c) => { c.modResults = infoPlist(c.modResults); return c; });
  config = AndroidConfig.Permissions.withPermissions(config, androidPermissions([]));
  return config;
};
