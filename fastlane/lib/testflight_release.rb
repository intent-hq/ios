require "open3"

# Release orchestration shared by TestFlight channels; never selects a build
# by "latest", or a group by name without checking that it is internal.
module TestflightRelease
  def self.boolean_option(options, key, default:)
    value = options.fetch(key, default)
    return true if value == true || value == "true"
    return false if value == false || value == "false"
    ReleaseSupport.fail!("#{key} must be true or false.")
  end

  def self.git(*args)
    stdout, _stderr, status = Open3.capture3("git", *args, chdir: ReleaseSupport::ROOT)
    ReleaseSupport.fail!("Git #{args.first} failed; ensure full history and TestFlight tags are fetched.") unless status.success?
    stdout
  end

  def self.notes(channel:, head:)
    if channel == "alpha"
      arguments = ["--commit", "--", head]
    else
      tags = git("tag", "--merged", head, "--list", "testflight/#{channel}/*").lines.map(&:strip)
      base = tags.select { |tag| tag.match?(%r{\Atestflight/#{Regexp.escape(channel)}/\d+\z}) }
        .max_by { |tag| tag.split("/").last.to_i }
      unless base
        base = git("rev-list", "--max-parents=0", "--first-parent", head).lines.last.strip
        FastlaneCore::UI.message("No previous #{channel} tag; notes start at repository root #{base}.")
        return "Initial #{channel.capitalize} build.\n" if base == head
      end
      arguments = [base, head]
    end
    text, _stderr, status = Open3.capture3("python3", File.join(ReleaseSupport::ROOT, "scripts/release_notes.py"), *arguments, chdir: ReleaseSupport::ROOT)
    ReleaseSupport.fail!("Release notes failed (exit #{status.exitstatus}); refusing to upload without notes.") unless [0, 3].include?(status.exitstatus)
    text
  end

  def self.internal_group(name)
    groups = ReleaseSupport.app.get_beta_groups.select { |group| group.name == name && group.is_internal_group == true }
    ReleaseSupport.fail!("Expected exactly one internal #{name} TestFlight group, found #{groups.length}. External groups are never used.") unless groups.length == 1
    groups.first
  end

  def self.distribute(artifact, group)
    platform = artifact.fetch(:platform) == "visionos" ? "VISION_OS" : "IOS"
    builds = Spaceship::ConnectAPI::Build.all(
      app_id: ReleaseSupport.app.id, version: artifact.fetch(:version),
      build_number: artifact.fetch(:build_number).to_s, platform: platform,
      processing_states: "VALID"
    )
    ReleaseSupport.fail!("Expected one processed #{platform} build #{artifact[:version]} (#{artifact[:build_number]}), found #{builds.length}.") unless builds.length == 1
    # Direct ID relationship avoids pilot's name-or-ID matching, which can
    # select both an internal and an external group named Alpha.
    builds.first.add_beta_groups(beta_groups: [group])
  end

  def self.push_tag(tag, commit)
    success = system({ "TESTFLIGHT_TAG" => tag, "TESTFLIGHT_COMMIT" => commit },
      "bash", File.join(ReleaseSupport::ROOT, ".github/scripts/push-testflight-tag.sh"), chdir: ReleaseSupport::ROOT)
    ReleaseSupport.fail!("Both platforms uploaded, but tagging failed. Push #{tag} on #{commit} before the next release.") unless success
  end

  def self.output(name, value)
    path = ENV["GITHUB_OUTPUT"]
    ReleaseSupport.fail!("defer_tag:true requires GITHUB_OUTPUT and a follow-up tag job.") if path.to_s.empty?
    File.open(path, "a") { |file| file.puts("#{name}=#{value}") }
  end

  def self.summary(channel:, release:, head:, notes:, statuses:)
    text = "## #{channel}: #{release[:version]} (#{release[:build_number]})\n\nCommit: #{head}\n\n"
    text += statuses.map { |platform, status| "- #{platform}: #{status}\n" }.join
    text += "\n### What to Test\n\n#{notes}\n"
    FastlaneCore::UI.message(text)
    File.open(ENV["GITHUB_STEP_SUMMARY"], "a") { |file| file.write(text) } if ENV["GITHUB_STEP_SUMMARY"]
  end
end