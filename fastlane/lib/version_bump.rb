require "json"
require "open3"
require_relative "release_support"

module VersionBump
  BRANCH = "automation/marketing-version-bump"
  PROJECT = "Intent.xcodeproj/project.pbxproj"
  CLOSED_STATES = %w[
    WAITING_FOR_REVIEW IN_REVIEW ACCEPTED PENDING_APPLE_RELEASE
    PENDING_DEVELOPER_RELEASE PENDING_CONTRACT WAITING_FOR_EXPORT_COMPLIANCE
    PROCESSING_FOR_APP_STORE PROCESSING_FOR_DISTRIBUTION READY_FOR_SALE
    READY_FOR_DISTRIBUTION PREORDER_READY_FOR_SALE REPLACED_WITH_NEW_VERSION
    DEVELOPER_REMOVED_FROM_SALE REMOVED_FROM_SALE
  ].freeze

  def self.plan(app, current)
    versions = app.get_app_store_versions(filter: { platform: "IOS,VISION_OS" }, includes: nil)
    matching = versions.select { |version| Gem::Version.new(version.version_string) == Gem::Version.new(current) }
    closed = matching.select do |version|
      state = version.app_version_state || version.app_store_state
      unless CLOSED_STATES.include?(state) || ReleaseSupport::EDITABLE_STATES.include?(state)
        ReleaseSupport.fail!("Unknown App Store version state for #{version.platform}; inspect App Store Connect before bumping.")
      end
      CLOSED_STATES.include?(state)
    end
    return nil if closed.empty?

    parts = current.split(".").map { |part| Integer(part, 10) }
    parts << 0 if parts.length == 2
    parts[2] += 1
    next_version = parts.join(".")
    # Do not propose a patch that is already closed (or behind a later release).
    # The shared upload guard also rejects unknown states rather than guessing.
    ReleaseSupport.version_guard(app, next_version)
    { from: current, to: next_version,
      reason: closed.map { |version| "#{version.platform}: #{version.app_version_state || version.app_store_state}" }.join(", ") }
  end

  def self.publish(plan)
    root = ReleaseSupport::ROOT
    repo = ENV.fetch("GITHUB_REPOSITORY", "intent-hq/ios")
    base = ENV.fetch("VERSION_BUMP_BASE", "main")
    command!(root, "git", "check-ref-format", "refs/heads/#{base}")
    prs = JSON.parse(command!(root, "gh", "pr", "list", "--repo", repo, "--head", BRANCH,
      "--state", "open", "--json", "number,baseRefName"))
    ReleaseSupport.fail!("Multiple version-bump PRs exist; keep only one before retrying.") if prs.length > 1
    if prs.first && prs.first.fetch("baseRefName") != base
      ReleaseSupport.fail!("The version-bump PR targets a different base branch; inspect it before retrying.")
    end
    command!(root, "git", "fetch", "origin", "+refs/heads/#{base}:refs/remotes/origin/#{base}")
    base_ref = "refs/remotes/origin/#{base}"
    source = command!(root, "git", "show", "#{base_ref}:#{PROJECT}")
    unless source == File.read(File.join(root, PROJECT))
      ReleaseSupport.fail!("MARKETING_VERSION project settings changed on #{base}; update your checkout and rerun the Apple check.")
    end
    updated = source.gsub(/(MARKETING_VERSION = )("?)([0-9.]+)\2;/) do
      ReleaseSupport.fail!("MARKETING_VERSION changed; rerun the Apple check.") unless Regexp.last_match(3) == plan.fetch(:from)
      "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{plan.fetch(:to)}#{Regexp.last_match(2)};"
    end
    ReleaseSupport.fail!("No MARKETING_VERSION settings found.") if updated == source

    remote = command!(root, "git", "ls-remote", "--heads", "origin", "refs/heads/#{BRANCH}").split.first
    if remote
      command!(root, "git", "fetch", "origin", "refs/heads/#{BRANCH}")
      # FETCH_HEAD can advance if another writer raced us; the explicit lease below
      # still refuses to replace a branch changed since ls-remote.
    end
    title = "chore: bump version to #{plan.fetch(:to)}"
    Dir.mktmpdir("intent-version-bump-") do |temporary|
      worktree = File.join(temporary, "checkout")
      command!(root, "git", "worktree", "add", "--detach", worktree, base_ref)
      begin
        File.write(File.join(worktree, PROJECT), updated)
        project = Xcodeproj::Project.open(File.join(worktree, "Intent.xcodeproj"))
        versions = project.targets.flat_map { |target| target.build_configurations.map { |config| config.build_settings["MARKETING_VERSION"] } }
        ReleaseSupport.fail!("Not every target/configuration received the new marketing version.") unless versions.uniq == [plan.fetch(:to)]
        command!(worktree, "git", "add", "--", PROJECT)
        tree = command!(worktree, "git", "write-tree").strip
        remote_tree = remote && command!(root, "git", "rev-parse", "#{remote}^{tree}").strip
        unless tree == remote_tree
          command!(worktree, "git", "-c", "user.name=github-actions[bot]", "-c",
            "user.email=41898282+github-actions[bot]@users.noreply.github.com", "commit", "-m", title)
          commit = command!(worktree, "git", "rev-parse", "HEAD").strip
          # Push from the original checkout so checkout's scoped credentials apply.
          command!(root, "git", "push", "--force-with-lease=refs/heads/#{BRANCH}:#{remote}",
            "origin", "#{commit}:refs/heads/#{BRANCH}")
        end
      ensure
        command!(root, "git", "worktree", "remove", "--force", worktree)
      end
    end
    body = "App Store Connect has closed #{plan.fetch(:from)} (#{plan.fetch(:reason)}).\n\n" \
      "Bumps MARKETING_VERSION to #{plan.fetch(:to)} for every target/configuration, shared by iOS and visionOS. " \
      "Build numbers are assigned from App Store Connect at build time. No upload, submission or release is performed.\n\n" \
      "Please review and merge this PR before the next TestFlight build."
    if prs.first
      command!(root, "gh", "pr", "edit", prs.first.fetch("number").to_s, "--repo", repo, "--title", title, "--body", body)
    else
      command!(root, "gh", "pr", "create", "--repo", repo, "--base", base, "--head", BRANCH, "--title", title, "--body", body)
    end
  end

  def self.command!(directory, *args)
    output, _error, status = Open3.capture3(*args, chdir: directory)
    # Do not print subprocess output: git/gh errors can contain authenticated URLs.
    ReleaseSupport.fail!("#{args.first} #{args[1]} failed (exit #{status.exitstatus}); check repository access and Actions PR permissions.") unless status.success?
    output
  end
end
