# Run with bundle exec ruby scripts/test-version-bump.rb. Apple and GitHub are
# stubbed at their boundaries; project parsing, git commits/pushes and lanes run.
require "fastlane"
require_relative "../fastlane/lib/version_bump"
Fastlane::Actions.load_default_actions

def check(name)
  yield
  puts "PASS: #{name}"
end

def equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def fails_with(text)
  begin
    yield
  rescue FastlaneCore::Interface::FastlaneError => error
    raise "Unexpected error: #{error.message}" unless error.message.include?(text)
    return
  end
  raise "Expected failure: #{text}"
end

class VersionPages
  def initialize(pages)
    @pages = pages
  end

  def all_pages
    @pages.map { |page| VersionPages.new([page]) }
  end

  def to_models
    @pages.first
  end
end

def version(number, state, platform = "IOS", legacy: false)
  Spaceship::ConnectAPI::AppStoreVersion.new("fixture", {
    "versionString" => number, "platform" => platform,
    (legacy ? "appStoreState" : "appVersionState") => state
  })
end

history = []
app = Spaceship::ConnectAPI::App.new("fixture-app", {})
Spaceship::ConnectAPI.define_singleton_method(:get_app_store_versions) do |**args|
  equal("fixture-app", args.fetch(:app_id))
  platforms = args.fetch(:filter).fetch(:platform).split(",")
  VersionPages.new(history.map { |page| page.select { |row| platforms.include?(row.platform) } })
end

check("submitted, approved and released versions on either platform produce the patch bump, including later pages") do
  %w[WAITING_FOR_REVIEW IN_REVIEW ACCEPTED PENDING_DEVELOPER_RELEASE READY_FOR_DISTRIBUTION REPLACED_WITH_NEW_VERSION].each do |state|
    %w[IOS VISION_OS].each do |platform|
      history.replace([[version("1.1.4", "READY_FOR_DISTRIBUTION")], [version("1.1.5", state, platform)]])
      plan = VersionBump.plan(app, "1.1.5")
      equal("1.1.6", plan.fetch(:to))
      equal("1.1.5", plan.fetch(:from))
      raise "Missing reason" unless plan.fetch(:reason).include?(platform)
    end
  end
  history.replace([[version("1.1", "READY_FOR_SALE", "VISION_OS", legacy: true)]])
  equal("1.1.1", VersionBump.plan(app, "1.1").fetch(:to))
end

check("absent, older and editable versions do not bump; unknown states and closed next patches fail safely") do
  history.clear
  equal(nil, VersionBump.plan(app, "1.1.5"))
  %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW REJECTED DEVELOPER_REJECTED METADATA_REJECTED INVALID_BINARY].each do |state|
    history.replace([[version("1.1.4", "READY_FOR_DISTRIBUTION"), version("1.1.5", state)]])
    equal(nil, VersionBump.plan(app, "1.1.5"))
  end
  history.replace([[version("1.1.5", "UNKNOWN")]])
  fails_with("Unknown App Store version state") { VersionBump.plan(app, "1.1.5") }
  history.replace([[version("1.1.5", "IN_REVIEW"), version("1.1.6", "ACCEPTED", "VISION_OS")]])
  fails_with("not open for a new release") { VersionBump.plan(app, "1.1.5") }
end

original_root = ReleaseSupport::ROOT
original_command = VersionBump.method(:command!)
saved_env = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY VERSION_BUMP_BASE GITHUB_REPOSITORY].to_h { |name| [name, ENV[name]] }
begin
  ENV["ASC_KEY_ID"] = "TESTKEY"
  ENV["ASC_ISSUER_ID"] = "TESTISSUER"
  ENV["ASC_PRIVATE_KEY"] = OpenSSL::PKey::EC.generate("prime256v1").to_pem
  ENV["VERSION_BUMP_BASE"] = "main"
  ENV["GITHUB_REPOSITORY"] = "fixture/ios"
  Spaceship::ConnectAPI::App.define_singleton_method(:find) { |_identifier| app }
  fastfile = Fastlane::FastFile.new(File.join(original_root, "fastlane", "Fastfile"))
  run_lane = ->(options) { fastfile.runner.execute(:check_version_bump, :ios, options) }
  Dir.mktmpdir("version-bump-test-") do |temporary|
    root = File.join(temporary, "repo")
    FileUtils.mkdir_p(File.join(root, "Intent.xcodeproj"))
    original = File.read(File.join(original_root, VersionBump::PROJECT))
    source = original.gsub(/MARKETING_VERSION = [0-9.]+;/, "MARKETING_VERSION = 1.1.5;")
    File.write(File.join(root, VersionBump::PROJECT), source)
    ReleaseSupport.send(:remove_const, :ROOT)
    ReleaseSupport.const_set(:ROOT, root)
    git = ->(*args) { original_command.call(root, "git", *args).strip }
    git.call("init", "--initial-branch=main")
    git.call("config", "user.name", "Release fixture")
    git.call("config", "user.email", "fixture@example.invalid")
    git.call("add", ".")
    git.call("commit", "-m", "initial fixture")
    remote = File.join(temporary, "remote.git")
    git.call("init", "--bare", remote)
    git.call("remote", "add", "origin", remote)
    git.call("push", "origin", "main")
    prs = []
    calls = []
    fail_create = false
    VersionBump.define_singleton_method(:command!) do |directory, *args|
      if args.first != "gh"
        next original_command.call(directory, *args)
      end
      calls << args
      case args[2]
      when "list" then JSON.generate(prs)
      when "create"
        ReleaseSupport.fail!("Fixture GitHub creation failure") if fail_create
        raise "Duplicate PR" unless prs.empty?
        prs << { "number" => 42, "baseRefName" => "main" }
        "fixture PR created"
      when "edit"
        equal("42", args[3])
        "fixture PR updated"
      else raise "Unexpected GitHub write"
      end
    end
    check("public dry run authenticates and prints a real decision without changing files, git or GitHub") do
      history.replace([[version("1.1.5", "PREPARE_FOR_SUBMISSION")], [version("1.1.5", "IN_REVIEW", "VISION_OS")]])
      output = []
      ui = FastlaneCore::UI.ui_object
      success = ui.method(:success)
      ui.define_singleton_method(:success) { |message| output << message }
      begin
        equal("1.1.6", run_lane.call(dry_run: "true").fetch(:to))
        history.replace([[version("1.1.5", "PREPARE_FOR_SUBMISSION")]])
        equal(nil, run_lane.call(dry_run: true))
      ensure
        ui.define_singleton_method(:success, success)
      end
      raise "Missing bump output" unless output.include?("would bump 1.1.5 → 1.1.6")
      raise "Missing no-op output" unless output.include?("no bump needed")
      equal(source, File.read(File.join(root, VersionBump::PROJECT)))
      equal("", git.call("status", "--porcelain"))
      equal([], calls)
      equal("", git.call("ls-remote", "--heads", "origin", "refs/heads/#{VersionBump::BRANCH}"))
      fails_with("dry_run must be true or false") { run_lane.call(dry_run: "perhaps") }
    end

    check("public write lane changes all six versions, preserves build numbers and checkout, and reuses one PR without new commits") do
      history.replace([[version("1.1.5", "IN_REVIEW", "VISION_OS")]])
      run_lane.call(dry_run: false)
      equal(1, prs.length)
      git.call("fetch", "origin", VersionBump::BRANCH)
      first_commit = git.call("rev-parse", "FETCH_HEAD")
      bumped = git.call("show", "FETCH_HEAD:#{VersionBump::PROJECT}") + "\n"
      equal(6, bumped.scan("MARKETING_VERSION = 1.1.6;").length)
      equal(source, bumped.gsub("MARKETING_VERSION = 1.1.6;", "MARKETING_VERSION = 1.1.5;"))
      equal(VersionBump::PROJECT, git.call("diff", "--name-only", "main", "FETCH_HEAD"))
      run_lane.call(dry_run: "false")
      equal(1, prs.length)
      equal(1, calls.count { |args| args[2] == "create" })
      equal(1, calls.count { |args| args[2] == "edit" })
      equal("chore: bump version to 1.1.6", calls.last[calls.last.index("--title") + 1])
      git.call("fetch", "origin", VersionBump::BRANCH)
      equal(first_commit, git.call("rev-parse", "FETCH_HEAD"))
      equal(source, File.read(File.join(root, VersionBump::PROJECT)))
      equal("", git.call("status", "--porcelain"))
    end

    check("after merging a bump the same branch proposes the next version and recovers a failed PR creation") do
      git.call("merge", "--ff-only", "FETCH_HEAD")
      git.call("push", "origin", "main")
      prs.clear
      history.replace([[version("1.1.6", "READY_FOR_DISTRIBUTION")]])
      fail_create = true
      fails_with("Fixture GitHub creation failure") { run_lane.call({}) }
      pushed = git.call("ls-remote", "--heads", "origin", "refs/heads/#{VersionBump::BRANCH}")
      equal([], prs)
      fail_create = false
      run_lane.call({})
      equal(pushed, git.call("ls-remote", "--heads", "origin", "refs/heads/#{VersionBump::BRANCH}"))
      git.call("fetch", "origin", VersionBump::BRANCH)
      equal(6, git.call("show", "FETCH_HEAD:#{VersionBump::PROJECT}").scan("MARKETING_VERSION = 1.1.7;").length)
      equal(1, prs.length)
      equal("chore: bump version to 1.1.7", calls.last[calls.last.index("--title") + 1])
    end

    check("scheduled no-bump runs leave existing PRs and branches untouched") do
      history.replace([[version("1.1.6", "PREPARE_FOR_SUBMISSION")]])
      before_calls = calls.length
      equal(nil, run_lane.call(dry_run: false))
      equal(before_calls, calls.length)
    end

    check("stale checkout and duplicate PRs stop before pushing changes") do
      history.replace([[version("1.1.6", "READY_FOR_DISTRIBUTION")]])
      previous = git.call("ls-remote", "--heads", "origin", "refs/heads/#{VersionBump::BRANCH}")
      path = File.join(root, VersionBump::PROJECT)
      current_source = File.read(path)
      File.write(path, current_source + "\n")
      fails_with("changed on main") { run_lane.call(dry_run: false) }
      File.write(path, current_source)
      prs << { "number" => 43, "baseRefName" => "main" }
      fails_with("Multiple version-bump PRs") { run_lane.call(dry_run: false) }
      equal(previous, git.call("ls-remote", "--heads", "origin", "refs/heads/#{VersionBump::BRANCH}"))
    end
  end
ensure
  VersionBump.define_singleton_method(:command!, original_command)
  ReleaseSupport.send(:remove_const, :ROOT)
  ReleaseSupport.const_set(:ROOT, original_root)
  saved_env.each { |name, value| ENV[name] = value }
  Fastlane::Actions.lane_context.clear
  Spaceship::ConnectAPI.token = nil
end
