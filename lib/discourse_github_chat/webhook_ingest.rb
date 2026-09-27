# frozen_string_literal: true

require "json"

module DiscourseGithubChat
  class WebhookIngest
    SUPPORTED_EVENTS = %w[issues push release].freeze

    Result = Struct.new(
      :queued,
      :duplicate,
      :event_type,
      :delivery_id,
      :error,
      keyword_init: true,
    )

    def self.call(...)
      new(...).call
    end

    def initialize(delivery_id:, event_type:, payload:, payload_sha256:)
      @delivery_id = delivery_id.to_s
      @event_type = event_type.to_s.downcase
      @payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
      @payload_sha256 = payload_sha256.to_s
    end

    def call
      installation_id = positive_integer(nested_hash("installation")["id"])
      allowed_ids = Configuration.github_allowed_installation_ids
      if allowed_ids.any? && !allowed_ids.include?(installation_id)
        return Result.new(
          queued: false,
          duplicate: false,
          event_type: @event_type,
          delivery_id: @delivery_id,
          error: :installation_not_allowed,
        )
      end

      unless SUPPORTED_EVENTS.include?(@event_type)
        record_installation(installation_id)
        return Result.new(
          queued: false,
          duplicate: false,
          event_type: @event_type,
          delivery_id: @delivery_id,
        )
      end

      repository_id = positive_integer(nested_hash("repository")["id"])
      return ignored_result unless repository_id

      event_key = semantic_event_key(repository_id)
      safe_payload = minimized_payload

      delivery =
        DiscourseGithubChat::GithubDelivery.find_by(delivery_id: @delivery_id)
      if delivery
        return duplicate_result(delivery)
      end

      record_installation(installation_id)

      begin
        delivery = DiscourseGithubChat::GithubDelivery.create!(
          delivery_id: @delivery_id,
          event_type: @event_type,
          event_key: event_key,
          payload_sha256: @payload_sha256,
          payload: safe_payload,
          status: "queued",
        )
      rescue ActiveRecord::RecordNotUnique
        delivery = DiscourseGithubChat::GithubDelivery.find_by!(delivery_id: @delivery_id)
        return duplicate_result(delivery)
      end

      Jobs.enqueue(
        Jobs::ProcessDiscourseGithubChatDelivery,
        github_delivery_id: delivery.id,
      )

      Result.new(
        queued: true,
        duplicate: false,
        event_type: @event_type,
        delivery_id: @delivery_id,
      )
    end

    private

    def ignored_result
      Result.new(
        queued: false,
        duplicate: false,
        event_type: @event_type,
        delivery_id: @delivery_id,
      )
    end

    def duplicate_result(delivery)
      if delivery.payload_sha256 != @payload_sha256
        return Result.new(
          queued: false,
          duplicate: false,
          event_type: @event_type,
          delivery_id: @delivery_id,
          error: :payload_conflict,
        )
      end

      Result.new(
        queued: false,
        duplicate: true,
        event_type: delivery.event_type,
        delivery_id: delivery.delivery_id,
      )
    end

    def record_installation(installation_id)
      return if installation_id.nil?
      return unless defined?(DiscourseGithubChat::GithubInstallation)

      installation = @payload["installation"]
      account = installation.is_a?(Hash) ? installation["account"] : nil
      account = {} unless account.is_a?(Hash)
      suspended_at = parse_time(installation["suspended_at"]) if installation.is_a?(Hash)
      action = @payload["action"].to_s
      if @event_type == "installation" && %w[deleted suspend].include?(action)
        suspended_at ||= Time.zone.now
      elsif @event_type == "installation" && action == "unsuspend"
        suspended_at = nil
      end

      record = DiscourseGithubChat::GithubInstallation.find_or_initialize_by(
        github_installation_id: installation_id,
      )
      effective_suspended_at =
        if @event_type == "installation" && action == "unsuspend"
          nil
        else
          suspended_at || record.suspended_at
        end
      record.assign_attributes(
        account_login: scalar(account["login"], 255),
        account_type: scalar(account["type"], 64),
        suspended_at: effective_suspended_at,
        last_event_at: Time.zone.now,
      )
      record.save!

      if token_invalidation_event?
        DiscourseGithubChat::GitHubClient.clear_token_cache(installation_id)
      end
    end

    def token_invalidation_event?
      return true if %w[
        installation
        installation_repositories
      ].include?(@event_type)

      action = @payload["action"].to_s
      %w[
        created
        deleted
        suspend
        unsuspend
        new_permissions_accepted
        repositories_added
        repositories_removed
        added
        removed
      ].include?(action) || @payload.key?("repositories_added") || @payload.key?("repositories_removed")
    end

    def semantic_event_key(repository_id)
      case @event_type
      when "issues"
        issue_id = scalar(nested_hash("issue")["id"], 128)
        action = scalar(@payload["action"], 32)
        "issues:#{repository_id}:#{issue_id}:#{action}"
      when "push"
        ref = scalar(@payload["ref"], 220)
        after = scalar(@payload["after"], 128)
        "push:#{repository_id}:#{ref}:#{after}"
      when "release"
        release_id = scalar(nested_hash("release")["id"], 128)
        tag_name = scalar(nested_hash("release")["tag_name"], 220)
        "release:#{repository_id}:#{release_id.presence || tag_name}"
      else
        "delivery:#{@delivery_id}"
      end[0, 250]
    end

    def minimized_payload
      repository = nested_hash("repository")
      result = {
        "repository" => {
          "id" => positive_integer(repository["id"]),
          "full_name" => scalar(repository["full_name"], 255),
          "html_url" => scalar(repository["html_url"], 2048),
          "private" => repository["private"] == true,
        },
      }

      case @event_type
      when "issues"
        issue = @payload["issue"].is_a?(Hash) ? @payload["issue"] : {}
        user = issue["user"].is_a?(Hash) ? issue["user"] : {}
        result["action"] = scalar(@payload["action"], 32)
        result["issue"] = {
          "id" => positive_integer(issue["id"]),
          "number" => scalar(issue["number"], 32),
          "title" => scalar(issue["title"], 1_000),
          "html_url" => scalar(issue["html_url"], 2048),
          "user" => { "login" => scalar(user["login"], 255) },
        }
      when "push"
        result.merge!(minimized_push_payload)
      when "release"
        result["action"] = scalar(@payload["action"], 32)
        result["release"] = minimized_release
      end

      result
    end

    def minimized_release
      release = @payload["release"].is_a?(Hash) ? @payload["release"] : {}
      author = release["author"].is_a?(Hash) ? release["author"] : {}
      {
        "id" => positive_integer(release["id"]),
        "tag_name" => scalar(release["tag_name"], 220),
        "name" => scalar(release["name"], 255),
        "html_url" => scalar(release["html_url"], 2_048),
        "draft" => release["draft"] == true,
        "prerelease" => release["prerelease"] == true,
        "target_commitish" => scalar(release["target_commitish"], 255),
        "author" => { "login" => scalar(author["login"], 255) },
      }
    end

    def minimized_push_payload
      commits = @payload["commits"].is_a?(Array) ? @payload["commits"] : []
      max_commits = Configuration.max_commits_in_summary
      {
        "ref" => scalar(@payload["ref"], 256),
        "before" => scalar(@payload["before"], 128),
        "after" => scalar(@payload["after"], 128),
        "created" => @payload["created"] == true,
        "deleted" => @payload["deleted"] == true,
        "forced" => @payload["forced"] == true,
        "size" => integer_or_nil(@payload["size"]),
        "commit_count" => commits.length,
        "commits" => commits.first(max_commits).filter_map { |commit| minimized_commit(commit) },
        "head_commit" => minimized_commit(@payload["head_commit"]),
      }
    end

    def minimized_commit(commit)
      return unless commit.is_a?(Hash)

      author = commit["author"].is_a?(Hash) ? commit["author"] : {}
      {
        "id" => scalar(commit["id"] || commit["sha"], 128),
        "url" => scalar(commit["url"], 2048),
        "message" => scalar(commit["message"], 4_000),
        "author" => {
          "name" => scalar(author["name"], 255),
          "username" => scalar(author["username"], 255),
        },
      }
    end

    def nested_hash(key)
      value = @payload[key]
      value.is_a?(Hash) ? value : {}
    end

    def scalar(value, limit)
      return if value.nil?
      return value if value == true || value == false
      return value.to_i if value.is_a?(Numeric)

      value.to_s.each_char.select { |character| character.match?(/[[:print:]]/) || character.match?(/\s/) }
        .join.tr("\r\n\t", "   ").strip[0, limit]
    end

    def integer_or_nil(value)
      return if value.nil? || value == ""

      Integer(value, exception: false)
    end

    def positive_integer(value)
      integer = Integer(value, exception: false)
      integer if integer&.positive?
    end

    def parse_time(value)
      return if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
