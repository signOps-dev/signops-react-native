require "json"
package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# The React Native module for iOS. It compiles the SignOps Swift package's sources (copied into ios/sdk by npm run sync)
# with a thin bridge.
Pod::Spec.new do |s|
  s.name         = "SignOpsReactNative"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://signops.dev/docs/"
  s.license      = "MIT"
  s.author       = "SignOps"
  s.platforms    = { :ios => "16.0" }
  s.source       = { :git => "https://github.com/signops-dev/signops-react-native.git", :tag => "v#{s.version}" }
  s.source_files = "ios/*.{swift,m}", "ios/sdk/*.swift"
  s.swift_version = "5.7"
  s.frameworks   = "AuthenticationServices", "LocalAuthentication", "Security"
  s.dependency "React-Core"
end
