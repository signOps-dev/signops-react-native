// Autolinking: the Android package class and the iOS pod.
module.exports = {
  dependency: {
    platforms: {
      android: { packageImportPath: "import com.signops.reactnative.SignOpsPackage;", packageInstance: "new SignOpsPackage()" },
      ios: { podspecPath: __dirname + "/SignOpsReactNative.podspec" },
    },
  },
};
