require "json"
require "open3"
require_relative "release_support"

# Commit statuses survive later uploads of the same commit. Workflow history is
# only a candidate index: a run's head alone is never evidence of an upload.
module ReleaseProvenance
  def self.repository
    ENV.fetch("GITHUB_REPOSITORY", "intent-hq/ios")
  end

  def self.command!(*args)
    output, _error, status = Open3.capture3(*args, chdir: ReleaseSupport::ROOT)
    # Subprocess errors may contain authenticated URLs; never echo them.
    ReleaseSupport.fail!("#{args.first} #{args[1]} failed (exit #{status.exitstatus}); check release-history permissions and repository access.") unless status.success?
    output.strip
  end

  def self.github(path, *args)
    JSON.parse(command!("gh", "api", "repos/#{repository}/#{path}", *args))
  end

  def self.validate_commit!(commit)
    ReleaseSupport.fail!("Release source must be a full 40-character commit SHA; refusing to guess.") unless commit.to_s.match?(/\A[0-9a-f]{40}\z/)
    commit
  end

  def self.record_upload(release:, head:)
    validate_commit!(head)
    github("statuses/#{head}", "--method", "POST", "-f", "state=success",
      "-f", "context=TestFlight", "-f", "description=#{release.fetch(:version)} (#{release.fetch(:build_number)})")
  end

  def self.upload_commits(version:, build:)
    pages = github("actions/workflows/testflight.yml/runs?per_page=100", "--paginate", "--slurp")
    runs = pages.flat_map { |page| page.fetch("workflow_runs") }
    if runs.length < pages.first.fetch("total_count")
      ReleaseSupport.fail!("Incomplete TestFlight workflow history; cannot prove the released build's commit.")
    end
    # Include failed/partial runs and old statuses, not just the latest combined
    # status (a repeated upload of one commit replaces that combined view).
    runs.map { |run| run.fetch("head_sha") }.uniq.select do |head|
      validate_commit!(head)
      statuses = github("commits/#{head}/statuses?per_page=100", "--paginate", "--slurp").flatten
      statuses.any? do |status|
        status["context"] == "TestFlight" && status["state"] == "success" &&
          status["description"] == "#{version} (#{build})"
      end
    end
  end
end