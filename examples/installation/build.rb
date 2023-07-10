#!/usr/bin/env ruby

require 'FileUtils'

def usage()
  puts <<~END
    Usage: ruby $0 test-all
    Usage: ruby $0 platform method [linkage]

    platform:
      ios
      osx
      tvos
      visionos
      watchos

    method:
      cocoapods
      carthage
      spm
      xcframework

    linkage:
      static
      dynamic (default)

    environment variables:
      REALM_XCODE_VERSION: Xcode version to use
      REALM_TEST_RELEASE: Version number to test, or "latest" to test the latest release
      REALM_TEST_BRANCH: Name of a branch to test
  END
  exit 1
end
usage unless ARGV.length >= 1

def read_setting(name)
  `sh -c 'source ../../scripts/swift-version.sh; set_xcode_and_swift_versions; echo "$#{name}"'`.chomp()
end

ENV['DEVELOPER_DIR'] = read_setting 'DEVELOPER_DIR'
ENV['REALM_XCODE_VERSION'] ||= read_setting 'REALM_XCODE_VERSION'

if ENV['REALM_TEST_RELEASE'] == 'latest'
  ENV['REALM_TEST_RELEASE'] = `curl --silent https://static.realm.io/update/cocoa`
end

TEST_RELEASE = ENV['REALM_TEST_RELEASE']
TEST_BRANCH = ENV['REALM_TEST_BRANCH']
XCODE_VERSION = ENV['REALM_XCODE_VERSION']
DEPENDENCIES = File.open("../../dependencies.list").map { |line| line.chomp.split("=") }.to_h

def replace_in_file(filepath, *args)
  contents = File.read(filepath)
  File.open(filepath, "w") do |file|
    args.each_slice(2) { |pattern, replacement|
      contents = contents.gsub pattern, replacement
    }
    file.puts contents
  end
end

def sh(*args)
  system(*args) or exit(1)
end

def download_release(version, language)
  unless Dir.exist? "realm-#{language}-#{version}"
    unless File.exist? "realm-#{language}-#{version}.zip"
      sh 'curl', '-OL', "https://github.com/realm/realm-swift/releases/download/v#{version}/realm-#{language}-#{version}.zip"
    end
    sh 'unzip', "realm-#{language}-#{version}.zip"
    FileUtils.rm "realm-#{language}-#{version}.zip"
  end
  unless language != 'swift' || Dir.exist?("realm-swift-#{version}/#{XCODE_VERSION}")
    raise "No build for Xcode version #{XCODE_VERSION} found in #{version} release package"
  end
  FileUtils.rm_rf '../../build/Realm.xcframework'
  FileUtils.rm_rf '../../build/RealmSwift.xcframework'
  FileUtils.mkdir_p '../../build'

  if language == 'swift'
    sh 'cp', '-cR', "realm-swift-#{version}/#{XCODE_VERSION}/Realm.xcframework", "../../build"
    sh 'cp', '-cR', "realm-swift-#{version}/#{XCODE_VERSION}/RealmSwift.xcframework", "../../build"
  elsif language == 'objc'
  FileUtils.mkdir_p '../../build/ios-static'
    sh 'cp', '-cR', "realm-objc-#{version}/ios-static/Realm.xcframework", "../../build/ios-static"
  else
    raise "Unknown language #{language}"
  end
end

def download_realm(platform, method, static)
  case method
  when 'cocoapods'
    # The podfile takes care of reading the env variables and importing the
    # correct thing
    ENV['REALM_PLATFORM'] = platform
    sh 'pod', 'install'

  when 'carthage'
    version = if TEST_RELEASE
      " == #{TEST_RELEASE}"
    elsif TEST_BRANCH
      " \"#{TEST_BRANCH}\""
    else
      ''
    end
    File.write 'Cartfile', 'github "realm/realm-swift"' + version

    # Carthage requires that a simulator exist, but `xcodebuild -list` is
    # sometimes very slow if too many simulators exist, so delete all but one
    # per platform
    sh '../../scripts/reset-simulators.rb', '-firstOnly'

    platformName = case platform
                   when 'ios' then 'iOS'
                   when 'osx' then 'Mac'
                   when 'tvos' then 'tvOS'
                   when 'watchos' then 'watchOS'
                   end
    sh 'carthage', 'update', '--use-xcframeworks', '--platform', platformName

  when 'spm'
    # We have to hide the spm example from carthage because otherwise
    # it'll fetch the example's package dependencies as part of deciding
    # what to build from this repo.
    unless File.symlink? 'SwiftPackageManager.xcodeproj/project.pbxproj'
      FileUtils.mkdir_p 'SwiftPackageManager.xcodeproj'
      File.symlink '../SwiftPackageManager.notxcodeproj/project.pbxproj',
                   'SwiftPackageManager.xcodeproj/project.pbxproj'
    end

    if TEST_RELEASE
      replace_in_file 'SwiftPackageManager.xcodeproj/project.pbxproj',
        /(branch|version) = .*;/, "version = #{TEST_RELEASE};",
        /kind = .*;/, "kind = exactVersion;"
    elsif TEST_BRANCH
      replace_in_file 'SwiftPackageManager.xcodeproj/project.pbxproj',
        /(branch|version) = .*;/, "branch = #{TEST_BRANCH};",
        /kind = .*;/, "kind = branch;"
    end
    sh 'xcodebuild', '-project', 'SwiftPackageManager.xcodeproj', '-resolvePackageDependencies'

  when 'xcframework'
    version = TEST_BRANCH ? DEPENDENCIES['VERSION'] : TEST_RELEASE
    if version
      download_release version, static ? 'objc' : 'swift'
    elsif not Dir.exist? '../../build/Realm.xcframework'
      raise 'Missing XCFramework to test in ../../build'
    end

  else
    usage
  end
end

def build_app(platform, method, static)
  archive_path = "#{Dir.pwd}/out.xcarchive"
  FileUtils.rm_rf archive_path

  build_args = ['clean', 'archive', '-archivePath', archive_path]
  case platform
  when 'ios'
    build_args += ['-sdk', 'iphoneos', '-destination', 'generic/platform=iphoneos']
  when 'tvos'
    build_args += ['-sdk', 'appletvos', '-destination', 'generic/platform=appletvos']
  when 'watchos'
    build_args += ['-sdk', 'watchos', '-destination', 'generic/platform=watchos']
  when 'osx'
    build_args += ['-sdk', 'macosx', '-destination', 'generic/platform=macOS']
  when 'catalyst'
    build_args += ['-destination', 'generic/platform=macOS,variant=Mac Catalyst']
  end
  build_args += ['CODE_SIGN_IDENTITY=', 'CODE_SIGNING_REQUIRED=NO', 'AD_HOC_CODE_SIGNING_ALLOWED=YES']

  case method
  when 'cocoapods'
    sh 'xcodebuild', '-workspace', 'CocoaPods.xcworkspace', '-scheme', 'App', *build_args

  when 'carthage'
    sh 'xcodebuild', '-project', 'Carthage.xcodeproj', '-scheme', 'App', *build_args

  when 'spm'
    sh 'xcodebuild', '-project', 'SwiftPackageManager.xcodeproj', '-scheme', 'App', *build_args

  when 'xcframework'
    if static
      sh 'xcodebuild', '-project', 'Static/StaticExample.xcodeproj', '-scheme', 'StaticExample', *build_args
    else
      sh 'xcodebuild', '-project', 'XCFramework.xcodeproj', '-scheme', 'App', *build_args
    end
  end
end

def validate_build(static)
  has_frameworks = Dir["out.xcarchive/Products/Applications/**/Frameworks/*.framework"].length != 0
  if has_frameworks and static
    raise 'Static build configuration has embedded frameworks'
  elsif not has_frameworks and not static
    raise 'Dyanmic build configuration is missing embedded frameworks'
  end
end

def test(platform, method, linkage = 'dynamic')
  # Because we only have one target Xcode will choose to build us as a static
  # library when using spm
  static = linkage == 'static' || method == 'spm'
  if static
    ENV['REALM_BUILD_STATIC'] = '1'
  else
    ENV.delete 'REALM_BUILD_STATIC'
  end

  puts "Testing #{method} for #{platform}"

  download_realm(platform, method, static)
  build_app(platform, method, static)
  validate_build(static)
end

if ARGV[0] == 'test-all'
  platforms = ['ios', 'osx', 'tvos', 'watchos', 'catalyst']
  if /15\..*/ =~ XCODE_VERSION
    platforms += ['visionos']
  end

  for platform in platforms
    for method in ['cocoapods', 'carthage', 'spm', 'xcframework']
      next if platform == 'catalyst' && method == 'carthage'
      next if platform == 'visionos' && method != 'spm'
      test platform, method, 'dynamic'
    end

    test platform, 'cocoapods', 'static' unless platform == 'visionos'
  end

  test 'ios', 'xcframework', 'static'

else
  test(*ARGV)
end
