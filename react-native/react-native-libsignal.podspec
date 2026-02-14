require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-libsignal"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.0" }
  s.source       = { :git => package["repository"]["url"], :tag => s.version }

  s.source_files = [
    "ios/**/*.{h,m,mm}",
    "cpp/**/*.{h,cpp}",
  ]

  s.dependency "React-Core"
  s.dependency "React-callinvoker"
  s.dependency "ReactCommon/turbomodule/core"
  s.dependency "React-NativeModulesApple"

  # The prebuilt libsignal_ffi XCFramework for iOS (device + simulator)
  if File.exist?(File.join(__dir__, "ios", "libsignal_ffi.xcframework"))
    s.vendored_frameworks = "ios/libsignal_ffi.xcframework"
  else
    s.vendored_libraries = "ios/libsignal_ffi.a"
  end

  # System libraries required by the Rust static library
  s.libraries = "z"

  s.pod_target_xcconfig = {
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++17",
    "HEADER_SEARCH_PATHS" => '"$(PODS_ROOT)/Headers/Public/React-Core" "$(PODS_TARGET_SRCROOT)/cpp"',
    "ENABLE_BITCODE" => "NO",
  }
end
