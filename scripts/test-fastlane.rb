# Run with bundle exec ruby scripts/test-fastlane.rb. No Apple account, archive,
# simulator or third-party test framework is needed.
require "fastlane"
require_relative "../fastlane/lib/release_support"
Fastlane::Actions.load_default_actions

def check(name)
  yield
  puts "PASS: #{name}"
end

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def assert_error(text)
  begin
    yield
  rescue FastlaneCore::Interface::FastlaneError => error
    raise "Unexpected error: #{error.message}" unless error.message.include?(text)
    return
  end
  raise "Expected error containing #{text}"
end

# Stub only the network boundary; real Spaceship App methods still perform
# pagination and model access. A missing page must change the chosen number.
class FixturePage
  def initialize(pages)
    @pages = pages
  end

  def all_pages
    @pages.map { |records| FixturePage.new([records]) }
  end

  def to_models
    @pages.first
  end
end

remote = { builds: [[]], uploads: [[]], versions: [[]] }
Spaceship::ConnectAPI.define_singleton_method(:get_builds) do |**args|
  raise "Build history must not filter version, platform or processing state" unless args[:filter] == { app: "fixture-app" }
  FixturePage.new(remote[:builds])
end
Spaceship::ConnectAPI.define_singleton_method(:get_build_uploads) do |**args|
  assert_equal("fixture-app", args[:app_id])
  raise "Upload history must not be filtered" if args[:filter] && !args[:filter].empty?
  FixturePage.new(remote[:uploads])
end
Spaceship::ConnectAPI.define_singleton_method(:get_app_store_versions) do |**args|
  assert_equal({ platform: "IOS,VISION_OS" }, args[:filter])
  FixturePage.new(remote[:versions])
end
app = Spaceship::ConnectAPI::App.new("fixture-app", {})
def fixture_build(number, state = "VALID", expired: false)
  Spaceship::ConnectAPI::Build.new(number.to_s, { "version" => number, "processingState" => state, "expired" => expired })
end
def version(number, state, legacy: false, platform: "IOS")
  Spaceship::ConnectAPI::AppStoreVersion.new(number, {
    "versionString" => number, "platform" => platform,
    (legacy ? "appStoreState" : "appVersionState") => state
  })
end

check("empty Apple history starts at 1, not the checkout build number") do
  assert_equal(1, ReleaseSupport.next_build_number(app))
end
check("uses numeric maximum across older pages, expired/processing builds and pending uploads") do
  remote[:builds] = [[fixture_build("9"), fixture_build("10")], [fixture_build("800", "FAILED", expired: true), fixture_build("90", "PROCESSING")]]
  remote[:uploads] = [[Spaceship::ConnectAPI::BuildUpload.new("pending", { "cfBundleVersion" => "801", "platform" => "VISION_OS" })]]
  assert_equal(802, ReleaseSupport.next_build_number(app))
  remote[:uploads] = [[]]
  assert_equal(801, ReleaseSupport.next_build_number(app))
end
check("non-integer Apple build numbers fail instead of silently truncating") do
  remote[:builds] = [[fixture_build("1.2.3")]]
  assert_error("refusing to guess") { ReleaseSupport.next_build_number(app) }
  remote[:builds] = [[]]
end
check("a new or editable version passes without changing Apple state") do
  assert_equal("2.0.0", ReleaseSupport.version_guard(app, "2.0.0"))
  remote[:versions] = [[version("1.9", "READY_FOR_DISTRIBUTION")], [version("2.0.0", "PREPARE_FOR_SUBMISSION")]]
  assert_equal("2.0.0", ReleaseSupport.version_guard(app, "2.0.0"))
end
check("submitted, released and unknown states require the version-bump PR") do
  %w[WAITING_FOR_REVIEW IN_REVIEW PENDING_DEVELOPER_RELEASE READY_FOR_DISTRIBUTION REPLACED_WITH_NEW_VERSION FUTURE_STATE].each do |state|
    remote[:versions] = [[], [version("2.0.0", state)]]
    assert_error("Merge the version-bump PR") { ReleaseSupport.version_guard(app, "2.0.0") }
  end
  remote[:versions] = [[version("2.1", "READY_FOR_SALE", legacy: true)]]
  assert_error("Merge the version-bump PR") { ReleaseSupport.version_guard(app, "2.0.0") }
  remote[:versions] = [[version("2.0.0", "PREPARE_FOR_SUBMISSION")], [version("2.0.0", "IN_REVIEW", platform: "VISION_OS")]]
  assert_error("VISION_OS") { ReleaseSupport.version_guard(app, "2.0.0") }
  remote[:versions] = [[]]
end
check("missing credentials name the variables, not their values") do
  names = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY]
  saved = names.to_h { |name| [name, ENV.delete(name)] }
  begin
    assert_error(names.join(", ")) { ReleaseSupport.credentials }
  ensure
    saved.each { |name, value| ENV[name] = value }
  end
end
check("archive app identity and both version values must match") do
  Dir.mktmpdir do |dir|
    plist = { "CFBundleIdentifier" => "dev.intentapp.ios", "CFBundleShortVersionString" => "2.0.0", "CFBundleVersion" => "802", "CFBundleSupportedPlatforms" => ["iPhoneOS"] }
    path = File.join(dir, "Info.plist")
    Xcodeproj::Plist.write_to_path(plist, path)
    ReleaseSupport.verify_app!(dir, "2.0.0", 802, platform: "ios")
    assert_error("platform mismatch") { ReleaseSupport.verify_app!(dir, "2.0.0", 802, platform: "visionos") }
    %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion].each do |key|
      Xcodeproj::Plist.write_to_path(plist.merge(key => "wrong"), path)
      assert_error("Stop and rebuild") { ReleaseSupport.verify_app!(dir, "2.0.0", 802, platform: "ios") }
    end
  end
end

check("public preflight authenticates, reads project version and prints the Apple-derived pair without building") do
  fastfile = Fastlane::FastFile.new(File.join(ReleaseSupport::ROOT, "fastlane", "Fastfile"))
  lanes = fastfile.runner.lanes.fetch(:ios)
  raise "Screenshots must remain public" if lanes.fetch(:screenshots).is_private
  raise "Preflight must be callable without uploads" if lanes.fetch(:testflight_preflight).is_private
  %i[next_build_number version_guard build_app_for_testflight].each do |name|
    raise "#{name} must be private" unless lanes.fetch(name).is_private
  end
  saved_env = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY].to_h { |name| [name, ENV[name]] }
  saved_root = ReleaseSupport::ROOT
  app_lookup = Spaceship::ConnectAPI::App.method(:find)
  Spaceship::ConnectAPI::App.define_singleton_method(:find) { |_identifier| app }
  ReleaseSupport.define_singleton_method(:system) { |*_args| raise "Preflight must not archive or export" }
  begin
    ENV["ASC_KEY_ID"] = "TESTKEY"
    ENV["ASC_ISSUER_ID"] = "TESTISSUER"
    ENV["ASC_PRIVATE_KEY"] = OpenSSL::PKey::EC.generate("prime256v1").to_pem
    remote[:builds] = [[fixture_build("41")]]
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(saved_root, "Intent.xcodeproj"), dir)
      project = Xcodeproj::Project.open(File.join(dir, "Intent.xcodeproj"))
      project.targets.each do |target|
        target.build_configurations.each { |config| config.build_settings["MARKETING_VERSION"] = "9.8.7" }
      end
      project.save
      ReleaseSupport.send(:remove_const, :ROOT)
      ReleaseSupport.const_set(:ROOT, dir)
      assert_equal({ version: "9.8.7", build_number: 42 }, fastfile.runner.execute(:testflight_preflight, :ios))
      project.targets.first.build_configurations.first.build_settings["MARKETING_VERSION"] = "9.8.6"
      project.save
      assert_error("one numeric MARKETING_VERSION") { fastfile.runner.execute(:testflight_preflight, :ios) }
    end
  ensure
    ReleaseSupport.singleton_class.send(:remove_method, :system)
    Spaceship::ConnectAPI::App.define_singleton_method(:find, app_lookup)
    ReleaseSupport.send(:remove_const, :ROOT)
    ReleaseSupport.const_set(:ROOT, saved_root)
    saved_env.each { |name, value| ENV[name] = value }
    Fastlane::Actions.lane_context.clear
    Spaceship::ConnectAPI.token = nil
    remote[:builds] = [[]]
  end
end

check("both platforms archive/export the same pair, verify artifacts and clean up signing keys on failure") do
  saved_env = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY].to_h { |name| [name, ENV[name]] }
  saved_root = ReleaseSupport::ROOT
  app_lookup = Spaceship::ConnectAPI::App.method(:find)
  Spaceship::ConnectAPI::App.define_singleton_method(:find) { |_identifier| app }
  captured_key = nil
  calls = []
  scenario = :archive_mismatch
  ReleaseSupport.define_singleton_method(:system) do |env, script, *args, **options|
    next Kernel.system(env, script, *args, **options) unless env.is_a?(Hash)
    captured_key = env.fetch("ASC_KEY_PATH")
    assert_equal(0o600, File.stat(captured_key).mode & 0o777)
    assert_equal(nil, env.fetch("ASC_PRIVATE_KEY"))
    if script.end_with?("ci_post_clone.sh")
      calls << :tailcatkit
      remote[:builds] = [[fixture_build("802")]] if scenario == :collision
      next true
    end
    raise "Must use the blessed build wrapper" unless script.end_with?("scripts/xcodebuild.sh")
    calls << args.first
    if args.first.start_with?("export-")
      raise "Archive checks must stop export" if scenario == :archive_mismatch
      export = env.fetch("RELEASE_EXPORT_PATH")
      payload = File.join(export, "Payload")
      FileUtils.mkdir_p(payload)
      FileUtils.cp_r(File.join(env.fetch("RELEASE_ARCHIVE_PATH"), "Products", "Applications", "Intent.app"), payload)
      if scenario == :export_mismatch
        path = File.join(payload, "Intent.app", "Info.plist")
        plist = Xcodeproj::Plist.read_from_path(path).merge("CFBundleVersion" => "999")
        Xcodeproj::Plist.write_to_path(plist, path)
      end
      next Kernel.system("/usr/bin/zip", "-qr", File.join(export, "Intent.ipa"), "Payload", chdir: export)
    end
    archive_app = File.join(env.fetch("RELEASE_ARCHIVE_PATH"), "Products", "Applications", "Intent.app")
    FileUtils.mkdir_p(archive_app)
    Xcodeproj::Plist.write_to_path({
      "CFBundleIdentifier" => "dev.intentapp.ios",
      "CFBundleShortVersionString" => "2.0.0",
      "CFBundleVersion" => scenario == :archive_mismatch ? "801" : "802",
      "CFBundleSupportedPlatforms" => [args.first == "archive-ios" ? "iPhoneOS" : "XROS"]
    }, File.join(archive_app, "Info.plist"))
    export_options = Xcodeproj::Plist.read_from_path(env.fetch("RELEASE_EXPORT_OPTIONS"))
    assert_equal(false, export_options.fetch("manageAppVersionAndBuildNumber"))
    assert_equal("export", export_options.fetch("destination"))
    true
  end
  begin
    ENV["ASC_KEY_ID"] = "TESTKEY"
    ENV["ASC_ISSUER_ID"] = "TESTISSUER"
    ENV["ASC_PRIVATE_KEY"] = "-----BEGIN TEST FIXTURE-----\nnot a signing key\n"
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(saved_root, "Intent.xcodeproj"), dir)
      project = Xcodeproj::Project.open(File.join(dir, "Intent.xcodeproj"))
      project.targets.each do |target|
        target.build_configurations.each { |config| config.build_settings["MARKETING_VERSION"] = "2.0.0" }
      end
      project.save
      ReleaseSupport.send(:remove_const, :ROOT)
      ReleaseSupport.const_set(:ROOT, dir)
      assert_error("Stop and rebuild") { ReleaseSupport.build(version: "2.0.0", build_number: 802, platform: "ios") }
      assert_equal([:tailcatkit, "archive-ios"], calls)
      raise "Signing key was retained" if File.exist?(captured_key)
      calls.clear
      scenario = :collision
      assert_error("no longer available") { ReleaseSupport.build(version: "2.0.0", build_number: 802, platform: "ios") }
      assert_equal([:tailcatkit], calls)
      raise "Signing key was retained after collision" if File.exist?(captured_key)
      remote[:builds] = [[fixture_build("801")]]
      %w[ios visionos].each do |platform|
        calls.clear
        scenario = :success
        result = ReleaseSupport.build(version: "2.0.0", build_number: 802, platform: platform)
        expected_calls = ["archive-#{platform}", "export-#{platform}"]
        expected_calls.unshift(:tailcatkit) if platform == "ios"
        assert_equal(expected_calls, calls)
        assert_equal(802, result.fetch(:build_number))
        assert_equal(platform, result.fetch(:platform))
        raise "Exported IPA missing" unless File.file?(result.fetch(:ipa))
        raise "Signing key was retained after success" if File.exist?(captured_key)
      end
      scenario = :export_mismatch
      assert_error("Stop and rebuild") { ReleaseSupport.build(version: "2.0.0", build_number: 802, platform: "visionos") }
      raise "Signing key was retained after export mismatch" if File.exist?(captured_key)
    end
  ensure
    ReleaseSupport.singleton_class.send(:remove_method, :system)
    Spaceship::ConnectAPI::App.define_singleton_method(:find, app_lookup)
    ReleaseSupport.send(:remove_const, :ROOT)
    ReleaseSupport.const_set(:ROOT, saved_root)
    saved_env.each { |name, value| ENV[name] = value }
  end
end