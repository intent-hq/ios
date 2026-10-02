# Run with bundle exec ruby scripts/test-alpha.rb. Apple and archive boundaries
# are fixtures; notes selection and release-marker pushes use real temporary git.
require "fastlane"
require "pilot"
require "tmpdir"
require "fileutils"
require_relative "../fastlane/lib/release_support"
require_relative "../fastlane/lib/testflight_release"
Fastlane::Actions.load_default_actions

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def assert_error(text)
  begin
    yield
  rescue FastlaneCore::Interface::FastlaneError => error
    raise "Wrong failure: #{error.message}" unless error.message.include?(text)
    return
  end
  raise "Expected failure containing #{text}"
end

def command(*args, chdir:, env: {})
  output, error, status = Open3.capture3(env, *args, chdir: chdir)
  raise "Fixture command failed: #{error}" unless status.success?
  output.strip
end

class AlphaPage
  def initialize(models)
    @models = models
  end
  def all_pages
    [self]
  end
  def to_models
    @models
  end
end

root = ReleaseSupport::ROOT
fastfile = Fastlane::FastFile.new(File.join(root, "fastlane/Fastfile"))
saved_env = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY GITHUB_OUTPUT GITHUB_STEP_SUMMARY].to_h { |key| [key, ENV[key]] }
ENV["ASC_KEY_ID"] = "TESTKEY"
ENV["ASC_ISSUER_ID"] = "TESTISSUER"
ENV["ASC_PRIVATE_KEY"] = OpenSSL::PKey::EC.generate("prime256v1").to_pem
events = []
remote_groups = []
uploaded = []
failure = nil
app = Spaceship::ConnectAPI::App.new("fixture-app", {})
Spaceship::ConnectAPI::App.define_singleton_method(:find) { |_identifier| app }
Spaceship::ConnectAPI.define_singleton_method(:get_build_uploads) { |**_args| AlphaPage.new([]) }
Spaceship::ConnectAPI.define_singleton_method(:get_app_store_versions) { |**_args| AlphaPage.new([]) }
Spaceship::ConnectAPI.define_singleton_method(:get_beta_groups) { |**_args| AlphaPage.new(remote_groups) }
Spaceship::ConnectAPI.define_singleton_method(:get_builds) do |**args|
  if args[:filter].keys == [:app]
    AlphaPage.new([])
  else
    assert_equal(ReleaseSupport.marketing_version, args[:filter].fetch("preReleaseVersion.version"))
    assert_equal("1", args[:filter].fetch(:version))
    assert_equal("VALID", args[:filter].fetch(:processingState))
    AlphaPage.new(uploaded.map do |platform|
      Spaceship::ConnectAPI::Build.new(platform, {
        "version" => "1", "processingState" => "VALID",
        "preReleaseVersion" => Spaceship::ConnectAPI::PreReleaseVersion.new(platform, { "platform" => platform })
      })
    end)
  end
end
Spaceship::ConnectAPI.define_singleton_method(:add_beta_groups_to_build) do |build_id:, beta_group_ids:|
  assert_equal(["alpha-internal"], beta_group_ids)
  events << "group:#{build_id}"
  ReleaseSupport.fail!("fixture group failure") if failure == "group:#{build_id}"
end
ReleaseSupport.define_singleton_method(:build) do |version:, build_number:, platform:|
  events << "build:#{platform}"
  assert_equal(1, build_number)
  assert_equal(ReleaseSupport.marketing_version, version)
  ReleaseSupport.fail!("fixture archive failure") if failure == "build:#{platform}"
  ipa = File.join(ReleaseSupport::ROOT, "#{platform}.ipa")
  File.write(ipa, "archive boundary fixture")
  { version: version, build_number: build_number, platform: platform, ipa: ipa }
end
Pilot::BuildManager.define_method(:upload) do |config|
  platform = config[:app_platform] == "xros" ? "VISION_OS" : "IOS"
  assert_equal(["build:ios", "build:visionos"], events.grep(/^build:/))
  assert_equal(true, config[:skip_submission])
  assert_equal(false, config[:distribute_external])
  assert_equal(false, config[:submit_beta_review])
  assert_equal(false, config[:notify_external_testers])
  assert_equal(false, config[:skip_waiting_for_build_processing])
  assert_equal("Features\n- newest change (#42)\n", config[:changelog])
  assert_equal(ReleaseSupport::APP_IDENTIFIER, config[:app_identifier])
  events << "upload:#{platform}"
  ReleaseSupport.fail!("fixture upload failure") if failure == "upload:#{platform}"
  uploaded << platform
end

begin
  Dir.mktmpdir("alpha-tests-") do |dir|
    FileUtils.cp_r(File.join(root, "Intent.xcodeproj"), dir)
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    FileUtils.cp(File.join(root, "scripts/release_notes.py"), File.join(dir, "scripts"))
    FileUtils.mkdir_p(File.join(dir, ".github/scripts"))
    FileUtils.cp(File.join(root, ".github/scripts/push-testflight-tag.sh"), File.join(dir, ".github/scripts"))
    ReleaseSupport.send(:remove_const, :ROOT)
    ReleaseSupport.const_set(:ROOT, dir)
    git = ->(*args) { command("git", *args, chdir: dir) }
    git.call("init", "--quiet")
    git.call("config", "user.name", "Release Test")
    git.call("config", "user.email", "release-test@example.invalid")
    commit = lambda do |message, date|
      command("git", "commit", "--allow-empty", "--quiet", "-m", message,
        chdir: dir, env: { "GIT_COMMITTER_DATE" => date })
    end
    commit.call("chore: root", "2000-01-01T00:00:00Z")
    git.call("tag", "testflight/alpha/9")
    commit.call("fix: previous change", "2000-01-02T00:00:00Z")
    previous = git.call("rev-parse", "HEAD")
    git.call("tag", "testflight/alpha/10")
    git.call("tag", "testflight/alpha/not-a-build")
    commit.call("feat: newest change (#42)", "2000-01-04T00:00:00Z")
    head = git.call("rev-parse", "HEAD")
    bare = File.join(dir, "remote.git")
    command("git", "init", "--bare", "--quiet", bare, chdir: dir)
    git.call("remote", "add", "origin", bare)
    ENV["GITHUB_OUTPUT"] = File.join(dir, "outputs")
    ENV["GITHUB_STEP_SUMMARY"] = File.join(dir, "summary")
    internal = Spaceship::ConnectAPI::BetaGroup.new("alpha-internal", { "name" => "Alpha", "isInternalGroup" => true })
    external = Spaceship::ConnectAPI::BetaGroup.new("alpha-external", { "name" => "Alpha", "isInternalGroup" => false })

    reset = lambda do
      events.clear
      uploaded.clear
      remote_groups.replace([external, internal])
      failure = nil
      File.write(ENV.fetch("GITHUB_OUTPUT"), "")
      File.write(ENV.fetch("GITHUB_STEP_SUMMARY"), "")
      Fastlane::Actions.lane_context.clear
    end
    run = ->(**options) { fastfile.runner.execute(:alpha, :ios, options) }
    reset.call
    run.call(upload: "false", defer_tag: true)
    assert_equal(["build:ios", "build:visionos"], events)
    assert_equal("", File.read(ENV.fetch("GITHUB_OUTPUT")))
    assert_equal("", git.call("ls-remote", "--tags", "origin"))
    summary = File.read(ENV.fetch("GITHUB_STEP_SUMMARY"))
    raise "Missing dry-run pair/notes/status" unless summary.include?("(1)") && summary.include?("newest change (#42)") && summary.include?("visionos: archived; not uploaded")
    puts "PASS: upload:false archives both, prints notes/pair, and does not upload or tag"

    reset.call
    run.call(upload: true, defer_tag: true)
    assert_equal(%w[build:ios build:visionos upload:IOS group:IOS upload:VISION_OS group:VISION_OS], events)
    assert_equal("tag=testflight/alpha/1\ncommit=#{head}\n", File.read(ENV.fetch("GITHUB_OUTPUT")))
    assert_equal("", git.call("ls-remote", "--tags", "origin"))
    puts "PASS: both archives precede uploads, internal group IDs exclude external Alpha, outputs capture built commit"

    ["build:visionos", "upload:VISION_OS", "group:VISION_OS"].each do |scenario|
      reset.call
      failure = scenario
      assert_error("fixture") { run.call(upload: true, defer_tag: true) }
      assert_equal("", File.read(ENV.fetch("GITHUB_OUTPUT")))
      assert_equal("", git.call("ls-remote", "--tags", "origin"))
      summary = File.read(ENV.fetch("GITHUB_STEP_SUMMARY"))
      if scenario.start_with?("build:")
        assert_equal([], events.grep(/^upload:/))
        raise "Missing platform failure" unless summary.include?("visionos: archive/export failed")
      else
        raise "Missing successful iOS upload" unless summary.include?("ios: uploaded, processed and distributed")
        raise "Missing failed visionOS status" unless summary.include?("visionos:") && summary.include?("failed")
      end
    end
    puts "PASS: platform archive/upload/distribution failures report partial state and never tag"

    [[external], [internal, internal]].each do |groups|
      reset.call
      remote_groups.replace(groups)
      assert_error("exactly one internal Alpha") { run.call(upload: true) }
      assert_equal([], events)
    end
    reset.call
    assert_error("upload must be true or false") { run.call(upload: "no") }
    assert_equal([], events)
    puts "PASS: missing/ambiguous internal groups and invalid upload options fail closed"

    reset.call
    run.call(upload: true)
    assert_equal("#{head}\trefs/tags/testflight/alpha/1", git.call("ls-remote", "--tags", "origin"))
    TestflightRelease.push_tag("testflight/alpha/1", head)
    assert_error("tagging failed") { TestflightRelease.push_tag("testflight/alpha/1", previous) }
    puts "PASS: successful lane pushes the captured commit; repeat tagging is safe and conflicting tags are refused"

    git.call("tag", "testflight/alpha/11", head)
    assert_equal("No changes.\n", TestflightRelease.notes(channel: "alpha", head: head))
    assert_error("Git tag failed") { TestflightRelease.notes(channel: "alpha", head: "missing-commit") }
    git.call("tag", "-d", "testflight/alpha/9", "testflight/alpha/10", "testflight/alpha/11")
    first_notes = TestflightRelease.notes(channel: "alpha", head: head)
    assert_equal("Features\n- newest change (#42)\n", first_notes)
    git.call("tag", "testflight/alpha/9", "#{previous}^")
    assert_equal("Features\n- newest change (#42)\n\nFixes\n- previous change\n",
      TestflightRelease.notes(channel: "alpha", head: head))
    puts "PASS: notes use numeric Alpha tags, preserve marked ranges, and bootstrap from only the last 24 hours"
  end
ensure
  ReleaseSupport.send(:remove_const, :ROOT)
  ReleaseSupport.const_set(:ROOT, root)
  saved_env.each { |key, value| ENV[key] = value }
end