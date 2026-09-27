# frozen_string_literal: true

require "base64"
require "uri"

module DiscourseGithubChat
  module Configuration
    module_function

    def enabled?
      SiteSetting.discourse_github_chat_enabled?
    end

    def github_app_id
      positive_integer(SiteSetting.discourse_github_chat_github_app_id)
    end

    def github_private_key
      value = SiteSetting.discourse_github_chat_github_private_key.to_s.strip
      value = value.gsub("\\n", "\n")
      return value if value.include?("-----BEGIN")

      # Some installations paste a base64-encoded PEM into a one-line setting.
      # Only try this when the value does not look like a PEM, so malformed
      # values are reported by the JWT signer rather than silently ignored.
      return "" if value.empty?

      decoded = Base64.decode64(value)
      decoded.include?("-----BEGIN") ? decoded : value
    rescue ArgumentError
      ""
    end

    def github_webhook_secret
      SiteSetting.discourse_github_chat_github_webhook_secret.to_s
    end

    def github_installation_id
      positive_integer(SiteSetting.discourse_github_chat_github_installation_id)
    end

    def github_allowed_installation_ids
      ids = integer_list(SiteSetting.discourse_github_chat_github_allowed_installation_ids)
      return ids.uniq.sort if ids.any?

      explicit = github_installation_id
      explicit ? [explicit] : []
    end

    def github_api_url
      value = SiteSetting.discourse_github_chat_github_api_url.to_s.strip
      value = "https://api.github.com" if value.empty?
      value.chomp("/")
    end

    def github_app_install_url
      SiteSetting.discourse_github_chat_github_app_install_url.to_s.strip
    end

    def bot_username
      value = SiteSetting.discourse_github_chat_bot_username.to_s.strip
      value.empty? ? "system" : value
    end

    def allowed_channel_ids
      integer_list(SiteSetting.discourse_github_chat_allowed_channel_ids)
    end

    def allow_private_repositories?
      SiteSetting.discourse_github_chat_allow_private_repositories?
    end

    def allow_direct_message_channels?
      SiteSetting.discourse_github_chat_allow_direct_message_channels?
    end

    def allow_public_channel_join?
      SiteSetting.discourse_github_chat_allow_public_channel_join?
    end

    def max_commits_in_summary
      value = SiteSetting.discourse_github_chat_max_commits_in_summary.to_s.to_i
      value.clamp(1, 100)
    end

    def command_rate_limit_per_minute
      value = SiteSetting.discourse_github_chat_command_rate_limit_per_minute.to_s.to_i
      value.clamp(1, 100)
    end

    def max_delivery_attempts
      value = SiteSetting.discourse_github_chat_max_delivery_attempts.to_s.to_i
      value.clamp(1, 20)
    end

    def github_app_configured?
      github_app_id.present? && github_private_key.present?
    end

    def integer_list(value)
      values =
        case value
        when Array
          value
        else
          value.to_s.split(/[|,\s]+/)
        end

      values.filter_map do |item|
        integer = positive_integer(item)
        integer if integer
      end.uniq.sort
    end

    def positive_integer(value)
      return value if value.is_a?(Integer) && value.positive?

      string = value.to_s.strip
      return if string.empty?

      integer = Integer(string, exception: false)
      integer if integer && integer.positive?
    end
  end
end
