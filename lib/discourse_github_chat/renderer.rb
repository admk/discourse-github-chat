# frozen_string_literal: true

require "uri"

module DiscourseGithubChat
  module Renderer
    MAX_INLINE_TEXT = 1_000
    MAX_COMMIT_SUBJECT = 300

    module_function

    def render_issue_event(payload, action)
      repository_name, repository_url = repository(payload)
      issue = hash(payload["issue"])
      issue_number = text(issue["number"], "?")
      title = markdown(issue["title"], "Untitled issue")
      issue_url = safe_url(issue["html_url"], repository_url)
      actor = text(hash(issue["user"])["login"], "")
      actor_text = actor.empty? ? "" : " by #{markdown(actor)}"
      verb = { "opened" => "opened", "closed" => "closed", "reopened" => "reopened" }.fetch(
        action,
        action,
      )

      "**GitHub issue #{verb}** — [#{repository_name}](#{repository_url})\n" \
        "##{issue_number} #{title}#{actor_text}\n" \
        "[View issue](#{issue_url})"
    end

    def render_release_event(payload)
      repository_name, repository_url = repository(payload)
      release = hash(payload["release"])
      action = payload["action"].to_s
      raw_tag_name = text(release["tag_name"], "release")
      tag_name = markdown(raw_tag_name, "release")
      release_name = text(release["name"], "")
      release_url = safe_url(release["html_url"], repository_url)
      kind =
        action == "prereleased" || release["prerelease"] == true ? "pre-release" : "release"

      lines = [
        "**GitHub #{kind} published** — [#{repository_name}](#{repository_url})",
        "[#{tag_name}](#{release_url})",
      ]
      if release_name.present? && release_name != raw_tag_name
        lines << markdown(release_name)
      end
      lines << "_Draft release._" if release["draft"] == true
      lines.join("\n")
    end

    def render_push_event(payload, max_commits:)
      repository_name, repository_url = repository(payload)
      ref = text(payload["ref"], "")
      branch = markdown(ref.split("/").last, "unknown")
      commits = payload["commits"].is_a?(Array) ? payload["commits"] : []
      head_commit = hash(payload["head_commit"])
      original_commit_count = payload["commit_count"].to_s.to_i
      original_commit_count = commits.length if original_commit_count <= 0
      original_commit_count = 1 if original_commit_count <= 0 && !head_commit.empty?
      total = positive_integer(payload["size"], original_commit_count)
      total = original_commit_count if total <= 0
      total = [total, commits.length].max if commits.length > total
      shown = commits.first(max_commits)

      lines = [
        "**GitHub push** — [#{repository_name}](#{repository_url})",
        "#{total} new commit#{total == 1 ? "" : "s"} on `#{branch}`",
      ]

      if shown.any?
        shown.each do |commit|
          commit = hash(commit)
          sha = text(commit["id"] || commit["sha"], "")
          short_sha = sha[0, 7].presence || "unknown"
          commit_url = commit_web_url(commit["url"], sha, repository_url)
          author = hash(commit["author"])
          author_name = markdown(author["name"] || author["username"], "unknown author")
          subject = markdown(first_line(commit["message"]), "No commit message")
          lines << "- [`#{short_sha}`](#{commit_url}) #{author_name}: #{subject}"
        end
      elsif !head_commit.empty?
        sha = text(head_commit["id"], "")
        commit_url = commit_web_url(head_commit["url"], sha, repository_url)
        subject = markdown(first_line(head_commit["message"]), "No commit message")
        lines << "- [`#{sha[0, 7].presence || "unknown"}`](#{commit_url}) #{subject}"
      end

      if total > shown.length && shown.any?
        lines << "- _…and #{total - shown.length} more commit(s) not included in the GitHub payload._"
      elsif shown.empty? && head_commit.empty?
        lines << "_No commit details were included in the GitHub payload._"
      end

      lines.join("\n")
    end

    def render_subscribe_response(repository_name:, repository_url:)
      "Subscribed this channel to [#{markdown(repository_name)}](#{safe_url(repository_url)})."
    end

    def render_already_subscribed_response(repository_name:, repository_url:)
      "This channel is already subscribed to [#{markdown(repository_name)}](#{safe_url(repository_url)})."
    end

    def render_unsubscribe_response(repository_name:, repository_url:)
      "Unsubscribed this channel from [#{markdown(repository_name)}](#{safe_url(repository_url)})."
    end

    def render_not_subscribed_response(repository_name:, repository_url: "https://github.com")
      "This channel is not subscribed to [#{markdown(repository_name)}](#{safe_url(repository_url)})."
    end

    def render_error_response(message)
      "GitHub Chat error: #{markdown(message)}"
    end

    def render_installation_required_response(install_url:)
      url = safe_url(install_url, "https://github.com/apps")
      "GitHub App installation is required before this channel can subscribe. " \
        "Install it here: [Install the GitHub App](#{url}). " \
        "Then send `/github subscribe <owner>/<repo>` again."
    end

    def render_help_response
      [
        "**GitHub Chat commands**",
        "- `/github subscribe <owner>/<repo>` — subscribe this channel to a repository",
        "- `/github unsubscribe <owner>/<repo>` — unsubscribe this channel from a repository",
        "- `/github help` — show this help message",
      ].join("\n")
    end

    def render_usage_response
      "Usage: `/github subscribe <owner>/<repo>`, `/github unsubscribe <owner>/<repo>`, " \
        "or `/github help`."
    end

    def repository(payload)
      repository = hash(payload["repository"])
      name = markdown(repository["full_name"], "unknown repository")
      [name, safe_url(repository["html_url"])]
    end

    def hash(value)
      value.is_a?(Hash) ? value : {}
    end

    def text(value, fallback = "")
      return fallback if value.nil?

      value
        .to_s
        .each_char
        .select { |character| character.match?(/[[:print:]]/) || character.match?(/\s/) }
        .join
        .tr("\r\n\t", "   ")
        .strip
        .then { |result| result[0, MAX_INLINE_TEXT].presence || fallback }
    end

    def markdown(value, fallback = "")
      escaped = text(value, fallback)
      escaped.gsub!("\\") { "\\\\" }
      escaped.gsub!("[") { "\\[" }
      escaped.gsub!("]") { "\\]" }
      escaped.gsub!("@") { "\\@" }
      escaped.gsub!("`") { "\\`" }
      escaped
    end

    def commit_web_url(value, sha, repository_url)
      candidate = value.to_s
      begin
        uri = URI.parse(candidate)
        if uri.host.present? && uri.path.include?("/commits/")
          candidate = "#{repository_url}/commit/#{sha}"
        end
      rescue URI::InvalidURIError
        candidate = "#{repository_url}/commit/#{sha}"
      end
      safe_url(candidate, "#{repository_url}/commit/#{sha}")
    end

    def safe_url(value, fallback = "https://github.com")
      candidate = text(value, fallback)
      uri = URI.parse(candidate)
      return fallback unless %w[http https].include?(uri.scheme) && uri.host.present?
      return fallback if uri.userinfo.present?

      candidate
        .gsub(" ", "%20")
        .gsub(")", "%29")
        .gsub("<", "%3C")
        .gsub(">", "%3E")
    rescue URI::InvalidURIError
      fallback
    end

    def first_line(value)
      value.to_s.split(/\r?\n/, 2).first.to_s[0, MAX_COMMIT_SUBJECT]
    end

    def positive_integer(value, fallback)
      integer = Integer(value, exception: false)
      integer && integer.positive? ? integer : fallback
    end
  end
end
