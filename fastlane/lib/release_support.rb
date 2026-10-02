require "base64"
require "fileutils"
require "tmpdir"
require "xcodeproj"
require "spaceship"

# Shared by the release lanes. Reading App Store Connect never changes its state.
module ReleaseSupport
  ROOT = File.expand_path("../..", __dir__)
  APP_IDENTIFIER = "dev.intentapp.ios"
  PLATFORMS = { "ios" => "iPhoneOS", "visionos" => "XROS" }.freeze
  EDITABLE_STATES = %w[
    PREPARE_FOR_SUBMISSION READY_FOR_REVIEW DEVELOPER_REJECTED
    REJECTED METADATA_REJECTED INVALID_BINARY
  ].freeze

  def self.fail!(message)
    FastlaneCore::UI.user_error!(message)
  end

  def self.credentials
    missing = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY].select { |name| ENV[name].to_s.strip.empty? }
    fail!("Missing App Store Connect credentials: #{missing.join(', ')}. Set these environment variables before running a release lane.") unless missing.empty?
    key = ENV.fetch("ASC_PRIVATE_KEY").gsub('\\n', "\n")
    key = Base64.strict_decode64(key) unless key.include?("-----BEGIN")
    { key_id: ENV.fetch("ASC_KEY_ID"), issuer_id: ENV.fetch("ASC_ISSUER_ID"), key_content: key }
  rescue ArgumentError
    fail!("ASC_PRIVATE_KEY must contain the .p8 private key, as PEM text or base64-encoded PEM.")
  end

  def self.app
    Spaceship::ConnectAPI::App.find(APP_IDENTIFIER) || fail!("App Store Connect app #{APP_IDENTIFIER} was not found or this API key cannot access it.")
  end

  def self.marketing_version
    project = Xcodeproj::Project.open(File.join(ROOT, "Intent.xcodeproj"))
    versions = project.targets.flat_map do |target|
      target.build_configurations.map { |config| config.build_settings["MARKETING_VERSION"] }
    end.uniq
    unless versions.length == 1 && versions.first.to_s.match?(/\A\d+\.\d+(?:\.\d+)?\z/)
      fail!("Intent.xcodeproj must use one numeric MARKETING_VERSION across all targets and configurations.")
    end
    versions.first
  end

  def self.next_build_number(app)
    # No version/platform/state/expiry filter: include iOS, visionOS and older
    # trains, including failed and processing builds. These helpers page fully.
    builds = app.get_builds(limit: 200)
    uploads = Spaceship::ConnectAPI.get_build_uploads(app_id: app.id, limit: 200)
      .all_pages.flat_map(&:to_models)
    numbers = builds.map(&:version) + uploads.map(&:cf_build_version)
    unless numbers.all? { |number| number.to_s.match?(/\A\d+\z/) }
      fail!("App Store Connect contains a non-integer or missing build number. Resolve the numbering scheme before releasing; refusing to guess a next build number.")
    end
    (numbers.map { |number| Integer(number.to_s, 10) }.max || 0) + 1
  end

  def self.version_guard(app, version)
    # Shared marketing version: either platform closing its train blocks both.
    # Read every page, not only the newest editable version.
    versions = app.get_app_store_versions(filter: { platform: "IOS,VISION_OS" }, includes: nil)
    blocked = versions.find do |remote|
      state = remote.app_version_state || remote.app_store_state
      Gem::Version.new(remote.version_string) >= Gem::Version.new(version) && !EDITABLE_STATES.include?(state)
    end
    if blocked
      state = blocked.app_version_state || blocked.app_store_state || "UNKNOWN"
      fail!("MARKETING_VERSION #{version} is not open for a new release: App Store Connect has #{blocked.version_string} (#{blocked.platform}) in #{state}. Merge the version-bump PR, update your checkout, and retry. Do not reuse or relabel an old archive.")
    end
    version
  end

  def self.verify_app!(app_path, version, build_number, platform:)
    plist_path = File.join(app_path, "Info.plist")
    fail!("Built app Info.plist is missing: #{plist_path}") unless File.file?(plist_path)
    plist = Xcodeproj::Plist.read_from_path(plist_path)
    actual = [plist["CFBundleShortVersionString"].to_s, plist["CFBundleVersion"].to_s]
    expected = [version.to_s, build_number.to_s]
    unless actual == expected && plist["CFBundleIdentifier"] == APP_IDENTIFIER
      fail!("Built app identity/version mismatch: expected #{APP_IDENTIFIER} #{expected.join(' (')}), found #{plist['CFBundleIdentifier']} #{actual.join(' (')}). Stop and rebuild; never relabel an archive.")
    end
    unless plist["CFBundleSupportedPlatforms"] == [PLATFORMS.fetch(platform)]
      fail!("Built app platform mismatch: expected #{platform}. Stop and rebuild for the correct destination.")
    end
  end

  def self.build(version:, build_number:, platform:)
    fail!("Release platform must be ios or visionos.") unless PLATFORMS.key?(platform)
    unless version == marketing_version
      fail!("The checked release version differs from MARKETING_VERSION. Run testflight_preflight again.")
    end
    output_root = File.join(ROOT, "build", "testflight")
    FileUtils.mkdir_p(output_root)
    output = Dir.mktmpdir("release-#{platform}-", output_root)
    archive = File.join(output, "Intent.xcarchive")
    export = File.join(output, "export")
    Dir.mktmpdir("intent-asc-") do |signing_dir|
      key_path = File.join(signing_dir, "AuthKey.p8")
      File.open(key_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(credentials.fetch(:key_content)) }
      export_options = File.join(signing_dir, "ExportOptions.plist")
      Xcodeproj::Plist.write_to_path({
        "method" => "app-store-connect", "destination" => "export",
        "signingStyle" => "automatic", "manageAppVersionAndBuildNumber" => false,
        "teamID" => "C26QN7DD6G"
      }, export_options)
      env = {
        "RELEASE_ARCHIVE_PATH" => archive, "RELEASE_EXPORT_PATH" => export,
        "RELEASE_EXPORT_OPTIONS" => export_options, "ASC_KEY_PATH" => key_path,
        "RELEASE_VERSION" => version, "RELEASE_BUILD_NUMBER" => build_number.to_s,
        "CI_PRODUCT_PLATFORM" => platform == "ios" ? "iOS" : "visionOS", "ASC_PRIVATE_KEY" => nil
      }
      run!(env, "ci_scripts/ci_post_clone.sh") if platform == "ios"
      # TailcatKit setup may take a while; fail before archiving if another
      # uploader consumed our number or the version was submitted meanwhile.
      remote_app = app
      version_guard(remote_app, version)
      if next_build_number(remote_app) > build_number
        fail!("App Store Connect changed during setup; build #{build_number} is no longer available. Retry the release lane.")
      end
      run!(env, "scripts/xcodebuild.sh", "archive-#{platform}")
      verify_app!(File.join(archive, "Products", "Applications", "Intent.app"), version, build_number, platform: platform)
      run!(env, "scripts/xcodebuild.sh", "export-#{platform}")
      ipas = Dir.glob(File.join(export, "*.ipa"))
      fail!("Expected one exported IPA in #{export}, found #{ipas.length}.") unless ipas.length == 1
      # Export must not silently renumber the verified archive either.
      Dir.mktmpdir("intent-export-check-") do |unpacked|
        fail!("Could not inspect exported IPA.") unless system("/usr/bin/unzip", "-q", ipas.first, "-d", unpacked)
        verify_app!(File.join(unpacked, "Payload", "Intent.app"), version, build_number, platform: platform)
      end
      return { version: version, build_number: build_number, platform: platform, archive_path: archive, ipa: ipas.first }
    end
  end

  def self.run!(env, script, *args)
    fail!("#{script} #{args.join(' ')} failed; see the command output above.") unless system(env, File.join(ROOT, script), *args, chdir: ROOT)
  end
end