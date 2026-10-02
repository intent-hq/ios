# Apple/GitHub boundary fixtures; the public lane and annotated tag pushes use
# real temporary git repositories. Run: bundle exec ruby scripts/test-app-store-release.rb
require "fastlane"
require "yaml"
require_relative "../fastlane/lib/app_store_release"
Fastlane::Actions.load_default_actions

def equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def fails_with(text)
  begin
    yield
  rescue FastlaneCore::Interface::FastlaneError => error
    raise "Unexpected failure: #{error.message}" unless error.message.include?(text)
    return
  end
  raise "Expected failure containing #{text}"
end

def version(number, state, platform = "IOS")
  { "type" => "appStoreVersions", "id" => "#{number}-#{platform}",
    "attributes" => { "versionString" => number, "platform" => platform, "appVersionState" => state } }
end

def response(data, client: nil, next_url: nil)
  Spaceship::ConnectAPI::Response.new(body: { "data" => data, "links" => { "next" => next_url } }, client: client)
end

root = ReleaseSupport::ROOT
command = ReleaseProvenance.method(:command!)
saved_env = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY GITHUB_OUTPUT GITHUB_REPOSITORY].to_h { |key| [key, ENV[key]] }
ENV["ASC_KEY_ID"] = "TESTKEY"
ENV["ASC_ISSUER_ID"] = "TESTISSUER"
ENV["ASC_PRIVATE_KEY"] = OpenSSL::PKey::EC.generate("prime256v1").to_pem
ENV["GITHUB_REPOSITORY"] = "fixture/ios"
history = []
builds = {}
cloud = {}
requests = []
runs = []
statuses = {}
product_available = true
reported_run_count = nil
app = Spaceship::ConnectAPI::App.new("fixture-app", {})
Spaceship::ConnectAPI::App.define_singleton_method(:find) { |_| app }
Spaceship::ConnectAPI.define_singleton_method(:get_app_store_versions) do |**args|
  equal("IOS,VISION_OS", args.fetch(:filter).fetch(:platform))
  response(history.take(1), client: self, next_url: "version-page-2")
end
Spaceship::ConnectAPI.define_singleton_method(:get) do |url|
  equal("version-page-2", url)
  response(history.drop(1))
end
Spaceship::ConnectAPI.define_singleton_method(:get_build) do |**args|
  response(builds[args.fetch(:app_store_version_id)])
end
Spaceship::ConnectAPI::APIClient.define_method(:get) do |path, params = nil|
  requests << [path, params]
  case path
  when "v1/apps/fixture-app"
    equal({ include: "ciProduct", fields: { apps: "ciProduct" } }, params)
    product = product_available ? { "type" => "ciProducts", "id" => "product" } : nil
    response({ "relationships" => { "ciProduct" => { "data" => product } } })
  when "v1/ciProducts/product/buildRuns"
    build_id = params.fetch(:filter).fetch(:builds)
    response([], client: self, next_url: "cloud-page-2/#{build_id}")
  when %r{\Acloud-page-2/}
    response(cloud.fetch(path.delete_prefix("cloud-page-2/"), []))
  else raise "Unexpected Apple URL #{path}"
  end
end
ReleaseProvenance.define_singleton_method(:command!) do |*args|
  next command.call(*args) unless args.first == "gh"
  equal(["--paginate", "--slurp"], args.last(2))
  path = args.fetch(2)
  if path == "repos/fixture/ios/actions/workflows/testflight.yml/runs?per_page=100"
    JSON.generate([{ "total_count" => reported_run_count || runs.length, "workflow_runs" => runs.take(1) }, { "workflow_runs" => runs.drop(1) }])
  elsif path =~ %r{\Arepos/fixture/ios/commits/([0-9a-f]{40})/statuses\?per_page=100\z}
    entries = statuses.fetch(Regexp.last_match(1), [])
    JSON.generate([entries.take(1), entries.drop(1)])
  else raise "Unexpected GitHub request #{path}"
  end
end

begin
  fastfile = Fastlane::FastFile.new(File.join(root, "fastlane/Fastfile"))
  Dir.mktmpdir("app-store-release-test-") do |dir|
    FileUtils.cp_r(File.join(root, "Intent.xcodeproj"), dir)
    project = File.join(dir, "Intent.xcodeproj/project.pbxproj")
    File.write(project, File.read(project).gsub(/MARKETING_VERSION = [0-9.]+;/, "MARKETING_VERSION = 1.1.9;"))
    ReleaseSupport.send(:remove_const, :ROOT)
    ReleaseSupport.const_set(:ROOT, dir)
    git = ->(*args) { command.call("git", *args) }
    git.call("init", "--initial-branch=main", "--quiet")
    git.call("config", "user.name", "Release Test")
    git.call("config", "user.email", "fixture@example.invalid")
    git.call("add", ".")
    git.call("commit", "--quiet", "-m", "released source")
    released = git.call("rev-parse", "HEAD")
    git.call("tag", "-a", "1.1.3", "-m", "Existing annotated release")
    git.call("commit", "--quiet", "--allow-empty", "-m", "newer main is not released")
    newer = git.call("rev-parse", "HEAD")
    git.call("init", "--bare", "--quiet", File.join(dir, "remote.git"))
    git.call("remote", "add", "origin", File.join(dir, "remote.git"))
    git.call("push", "origin", "main", "refs/tags/1.1.3")
    ENV["GITHUB_OUTPUT"] = File.join(dir, "outputs")
    lane = ->(**options) { fastfile.runner.execute(:check_version_bump, :ios, options) }
    set_release = lambda do |number, state, sources, build_numbers = ["214", "214"]|
      history.replace([version("1.0.0", "REPLACED_WITH_NEW_VERSION"), version("1.1.3", "REPLACED_WITH_NEW_VERSION")])
      %w[IOS VISION_OS].zip(sources, build_numbers).each do |platform, sha, build_number|
        row = version(number, state, platform)
        history << row
        id = "build-#{platform}-#{number}"
        builds[row.fetch("id")] = { "type" => "builds", "id" => id, "attributes" => { "version" => build_number } }
        cloud[id] = sha ? [{ "id" => "cloud-#{id}", "attributes" => { "sourceCommit" => { "commitSha" => sha }, "isPullRequestBuild" => false } }] : []
      end
    end
    set_release.call("1.1.4", "READY_FOR_DISTRIBUTION", [released, released])
    before = git.call("ls-remote", "--tags", "origin")
    output = []
    ui = FastlaneCore::UI.ui_object
    success = ui.method(:success)
    ui.define_singleton_method(:success) { |message| output << message }
    begin
      lane.call(dry_run: true)
      lane.call(dry_run: false, publish: false)
    ensure
      ui.define_singleton_method(:success, success)
    end
    raise "Missing exact dry-run tag" unless output.include?("would tag 1.1.4 at #{released} (annotated)")
    equal(before, git.call("ls-remote", "--tags", "origin"))
    equal("1.1.3", git.call("tag", "--list"))
    exported = JSON.parse(File.readlines(ENV.fetch("GITHUB_OUTPUT")).grep(/^release_tags=/).last.split("=", 2).last)
    equal(1, exported.length)
    equal(released, exported.first.fetch("commit"))
    puts "PASS: dry-run and separated planning backfill 1.1.4 despite newer marketing/main, without creating tags"

    lane.call(dry_run: false)
    equal("tag", git.call("cat-file", "-t", "refs/tags/1.1.4"))
    equal(released, git.call("rev-parse", "refs/tags/1.1.4^{}"))
    raise "Wrong remote release target" unless git.call("ls-remote", "--tags", "origin", "refs/tags/1.1.4^{}").start_with?(released)
    tagged = git.call("ls-remote", "--tags", "origin")
    requests.clear
    cloud.clear
    lane.call(dry_run: false)
    equal([], requests)
    equal(tagged, git.call("ls-remote", "--tags", "origin"))
    puts "PASS: both platforms create one annotated tag on the exact released commit; existing tags need no provenance and never move"

    %w[PREPARE_FOR_SUBMISSION IN_REVIEW ACCEPTED PENDING_DEVELOPER_RELEASE PREORDER_READY_FOR_SALE].each do |state|
      set_release.call("1.1.5", state, [released, released])
      lane.call(dry_run: true)
      equal(tagged, git.call("ls-remote", "--tags", "origin"))
    end
    puts "PASS: editable, submitted, approved and preorder versions are not releases"

    set_release.call("1.1.5", "REPLACED_WITH_NEW_VERSION", [nil, nil])
    product_available = false
    runs.replace([{ "head_sha" => newer, "conclusion" => "success" }, { "head_sha" => released, "conclusion" => "failure" }])
    status = { "context" => "TestFlight", "state" => "success", "description" => "1.1.5 (214)" }
    statuses[released] = [status.merge("description" => "1.1.5 (999)"), status]
    statuses[newer] = [status.merge("state" => "failure"), status.merge("context" => "Other")]
    lane.call(dry_run: false)
    equal(released, git.call("rev-parse", "refs/tags/1.1.5^{}"))
    puts "PASS: fastlane fallback finds exact old status on later pages, including partial failed runs and replaced releases"

    set_release.call("1.1.6", "READY_FOR_SALE", [nil, nil])
    original_tags = git.call("ls-remote", "--tags", "origin")
    fails_with("Cannot identify one exact commit") { lane.call(dry_run: false) }
    reported_run_count = runs.length + 1
    fails_with("Incomplete TestFlight workflow history") { lane.call(dry_run: false) }
    reported_run_count = nil
    status["description"] = "1.1.6 (214)"
    statuses[newer] = [status]
    fails_with("found 2") { lane.call(dry_run: false) }
    product_available = true
    set_release.call("1.1.6", "READY_FOR_DISTRIBUTION", [released, released])
    cloud.fetch("build-IOS-1.1.6") << { "attributes" => { "sourceCommit" => { "commitSha" => newer }, "isPullRequestBuild" => false } }
    fails_with("found 2") { lane.call(dry_run: false) }
    set_release.call("1.1.6", "READY_FOR_DISTRIBUTION", [released, newer])
    fails_with("platforms disagree") { lane.call(dry_run: false) }
    set_release.call("1.1.6", "READY_FOR_DISTRIBUTION", [released, released], ["214", "215"])
    fails_with("platforms disagree") { lane.call(dry_run: false) }
    set_release.call("1.1.6", "READY_FOR_DISTRIBUTION", ["short", released])
    fails_with("full 40-character") { lane.call(dry_run: false) }
    set_release.call("1.1.6", "READY_FOR_DISTRIBUTION", [released, released])
    cloud.values.last.first.fetch("attributes")["isPullRequestBuild"] = true
    fails_with("pull-request or unknown") { lane.call(dry_run: false) }
    builds.delete("1.1.6-IOS")
    fails_with("no selected build") { lane.call(dry_run: false) }
    equal(original_tags, git.call("ls-remote", "--tags", "origin"))
    puts "PASS: unknown, ambiguous, cross-platform mismatches, malformed/PR commits and missing selected builds fail without tags"

    set_release.call("1.1.6", "READY_FOR_DISTRIBUTION", [released, released])
    %w[IOS VISION_OS].each do |platform|
      history.each do |row|
        next unless row.fetch("attributes").fetch("versionString") == "1.1.6"
        row.fetch("attributes")["appVersionState"] = row.fetch("attributes").fetch("platform") == platform ? "READY_FOR_DISTRIBUTION" : "PENDING_DEVELOPER_RELEASE"
      end
      lane.call(dry_run: true)
      exported = JSON.parse(File.readlines(ENV.fetch("GITHUB_OUTPUT")).grep(/^release_tags=/).last.split("=", 2).last)
      equal([platform], exported.first.fetch("builds").map { |build| build.fetch("platform") })
    end
    equal(original_tags, git.call("ls-remote", "--tags", "origin"))
    puts "PASS: either platform can release first without tagging its still-pending counterpart"
    set_release.call("1.1.6", "READY_FOR_DISTRIBUTION", [released, released])
    plan = AppStoreRelease.plan(app)
    git.call("tag", "-a", "1.1.6", newer, "-m", "Concurrent human tag")
    git.call("push", "origin", "refs/tags/1.1.6")
    AppStoreRelease.publish(plan, dry_run: false)
    equal(newer, git.call("rev-parse", "1.1.6^{}"))
    raise "Concurrent tag moved" unless git.call("ls-remote", "--tags", "origin", "refs/tags/1.1.6^{}").start_with?(newer)
    puts "PASS: tag created between planning and publishing stays untouched"
  end
ensure
  ReleaseProvenance.define_singleton_method(:command!, command)
  ReleaseSupport.send(:remove_const, :ROOT)
  ReleaseSupport.const_set(:ROOT, root)
  saved_env.each { |key, value| ENV[key] = value }
  Spaceship::ConnectAPI.token = nil
end

# Workflow permissions are an independent security boundary that Ruby lane
# tests cannot exercise. Read-only planning must not inherit publisher scopes.
workflow = YAML.load_file(File.join(root, ".github/workflows/version-bump.yml"))
equal({ "contents" => "read" }, workflow.fetch("permissions"))
jobs = workflow.fetch("jobs")
equal({ "contents" => "read", "actions" => "read", "statuses" => "read" }, jobs.fetch("check-version").fetch("permissions"))
equal({ "contents" => "write" }, jobs.fetch("tag-release").fetch("permissions"))
equal({ "contents" => "write", "pull-requests" => "write" }, jobs.fetch("publish-bump").fetch("permissions"))
alpha = YAML.load_file(File.join(root, ".github/workflows/testflight.yml"))
equal({ "contents" => "read" }, alpha.fetch("permissions"))
equal({ "contents" => "read", "statuses" => "write" }, alpha.fetch("jobs").fetch("alpha").fetch("permissions"))
puts "PASS: workflow planning and uploads have no contents write; tag and PR writers are separately scoped"