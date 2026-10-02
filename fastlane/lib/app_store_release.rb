require_relative "release_provenance"

module AppStoreRelease
  RELEASED_STATES = %w[READY_FOR_SALE READY_FOR_DISTRIBUTION REPLACED_WITH_NEW_VERSION].freeze
  FIRST_AUTOMATED_VERSION = Gem::Version.new("1.1.4")

  def self.git(*args)
    ReleaseProvenance.command!("git", *args)
  end

  def self.existing_tag?(version)
    !git("ls-remote", "--tags", "origin", "refs/tags/#{version}").empty?
  end

  def self.validate_version!(version)
    ReleaseSupport.fail!("App Store tag must be a plain X.Y.Z version.") unless version.to_s.match?(/\A\d+\.\d+\.\d+\z/)
  end

  def self.cloud_commits(app_id, build_id)
    client = Spaceship::ConnectAPI::APIClient.new(token: Spaceship::ConnectAPI.token)
    # Read the optional linkage on the existing app: a missing related product
    # may return 404 from /ciProduct, but the app itself still exists.
    app = client.get("v1/apps/#{app_id}", { include: "ciProduct", fields: { apps: "ciProduct" } }).body.fetch("data")
    product = app.fetch("relationships").fetch("ciProduct").fetch("data")
    return [] unless product

    # Apple's ciProducts/buildRuns filter is by the App Store build's resource
    # ID, not the unrelated Xcode Cloud run number. Follow every response page.
    response = client.get("v1/ciProducts/#{product.fetch('id')}/buildRuns", {
      filter: { builds: build_id }, fields: { ciBuildRuns: "sourceCommit,isPullRequestBuild" }, limit: 200
    })
    response.all_pages.flat_map { |page| page.body.fetch("data") }.map do |run|
      attributes = run.fetch("attributes")
      unless attributes["isPullRequestBuild"] == false
        ReleaseSupport.fail!("Released build #{build_id} came from a pull-request or unknown Xcode Cloud run; cannot prove the built commit.")
      end
      ReleaseProvenance.validate_commit!(attributes.dig("sourceCommit", "commitSha"))
    end.uniq
  end

  def self.plan(app)
    versions = app.get_app_store_versions(filter: { platform: "IOS,VISION_OS" }, includes: nil)
    released = versions.select do |version|
      Gem::Version.new(version.version_string) >= FIRST_AUTOMATED_VERSION &&
        RELEASED_STATES.include?(version.app_version_state || version.app_store_state)
    end
    released.group_by(&:version_string).sort_by { |version, _| Gem::Version.new(version) }.filter_map do |version, platforms|
      validate_version!(version)
      if existing_tag?(version)
        FastlaneCore::UI.message("App Store tag #{version} already exists; leaving it unchanged.")
        next
      end
      builds = platforms.map do |platform|
        # AppStoreVersion#get_build raises "No data" for a null relationship;
        # inspect the envelope so this case has an actionable release error.
        response = Spaceship::ConnectAPI.get_build(app_store_version_id: platform.id)
        build = response.body.fetch("data") && response.to_models.first
        ReleaseSupport.fail!("Released #{platform.platform} #{version} has no selected build; refusing to tag.") unless build
        candidates = cloud_commits(app.id, build.id)
        candidates = ReleaseProvenance.upload_commits(version: version, build: build.version) if candidates.empty?
        unless candidates.length == 1
          ReleaseSupport.fail!("Cannot identify one exact commit for released #{platform.platform} #{version} (#{build.version}): found #{candidates.length}. Check Xcode Cloud sourceCommit and TestFlight statuses; refusing to guess.")
        end
        { platform: platform.platform, build: build.version, commit: candidates.first }
      end
      unless builds.map { |build| [build[:build], build[:commit]] }.uniq.length == 1
        ReleaseSupport.fail!("Released platforms disagree on the build/commit for #{version}; refusing to create one shared tag.")
      end
      { version: version, commit: builds.first.fetch(:commit), builds: builds }
    end
  end

  def self.publish(plans, dry_run:)
    plans.each do |plan|
      version = plan.fetch(:version)
      validate_version!(version)
      commit = ReleaseProvenance.validate_commit!(plan.fetch(:commit))
      # Recheck at the write boundary: never move a tag, including a racing writer.
      next if existing_tag?(version)
      if dry_run
        FastlaneCore::UI.success("would tag #{version} at #{commit} (annotated)")
        next
      end
      git("fetch", "--no-tags", "origin", commit)
      ReleaseSupport.fail!("Release source #{commit} is not a commit in this repository.") unless git("cat-file", "-t", commit) == "commit"
      message = "App Store #{version} — " + plan.fetch(:builds).map { |build| "#{build.fetch(:platform)} selected build #{build.fetch(:build)}" }.join(", ") + ", source #{commit}."
      git("-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "tag", "-a", version, commit, "-m", message)
      # No force, delete, or overwrite; a race is rejected by the remote.
      git("push", "origin", "refs/tags/#{version}:refs/tags/#{version}")
      FastlaneCore::UI.success("Created App Store tag #{version} at #{commit}.")
    end
  end
end