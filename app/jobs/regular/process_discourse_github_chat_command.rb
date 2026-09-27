# frozen_string_literal: true

module Jobs
  class ProcessDiscourseGithubChatCommand < ::Jobs::Base
    sidekiq_options queue: "default", retry: 10

    def execute(args)
      channel = nil
      response_key = nil

      message_id = args[:chat_message_id] || args["chat_message_id"]
      return if message_id.blank?
      return unless SiteSetting.discourse_github_chat_enabled?

      message = ::Chat::Message.find_by(id: message_id)
      return if message.nil? || message.deleted_at.present?

      channel = message.chat_channel
      user = message.user
      return if channel.nil? || user.nil?
      return if user.respond_to?(:bot?) && user.bot?
      return if user.id == DiscourseGithubChat::ChatPoster.bot_user.id
      return if channel.respond_to?(:membership_for) && channel.membership_for(user).nil?
      return unless DiscourseGithubChat::ChannelPolicy.allowed?(channel)

      parsed = DiscourseGithubChat::CommandParser.parse(message.message)
      return unless parsed.command?

      response_key = "command:#{message.id}"
      return if DiscourseGithubChat::ChatPoster.message_exists?(channel.id, response_key)

      unless command_allowed?(user, channel.id)
        respond(
          channel.id,
          response_key,
          DiscourseGithubChat::Renderer.render_error_response(
            "too many commands; please try again in a minute",
          ),
        )
        return
      end

      if parsed.help?
        respond(channel.id, response_key, DiscourseGithubChat::Renderer.render_help_response)
        return
      end

      if parsed.invalid || parsed.command.nil?
        respond(channel.id, response_key, DiscourseGithubChat::Renderer.render_usage_response)
        return
      end

      command = parsed.command
      if command.action == "unsubscribe"
        unsubscribe(command.repository_full_name, channel, response_key)
      else
        subscribe(command.repository_full_name, channel, user, response_key)
      end
    rescue DiscourseGithubChat::GitHubInstallationNotConfigured
      raise if channel.nil? || response_key.blank?

      respond(
        channel.id,
        response_key,
        DiscourseGithubChat::Renderer.render_installation_required_response(
          install_url: DiscourseGithubChat::GitHubClient.new.app_install_url,
        ),
      )
    rescue DiscourseGithubChat::GitHubError => e
      raise if e.retryable?
      raise if channel.nil? || response_key.blank?

      respond(channel.id, response_key, DiscourseGithubChat::Renderer.render_error_response(e.message))
    rescue DiscourseGithubChat::ChatPoster::PermanentError => e
      Rails.logger.warn("[discourse-github-chat] command response could not be posted: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("[discourse-github-chat] command processing failed: #{e.class}: #{e.message}")
      raise
    end

    private

    def command_allowed?(user, channel_id)
      RateLimiter.new(
        user,
        "github_chat_command_#{channel_id}",
        DiscourseGithubChat::Configuration.command_rate_limit_per_minute,
        60,
        apply_limit_to_staff: true,
      ).performed!(raise_error: false)
    end

    def subscribe(repository_full_name, channel, user, response_key)
      repository = DiscourseGithubChat::GitHubClient.new.repository(repository_full_name)
      if repository.private? && !DiscourseGithubChat::Configuration.allow_private_repositories?
        respond(
          channel.id,
          response_key,
          DiscourseGithubChat::Renderer.render_error_response(
            "repository is unavailable or cannot be subscribed on this bridge",
          ),
        )
        return
      end

      subscription = nil
      created = false
      DiscourseGithubChat::Subscription.transaction do
        subscription =
          DiscourseGithubChat::Subscription.find_or_initialize_by(
            github_repository_id: repository.id,
            chat_channel_id: channel.id,
          )
        created = subscription.new_record?
        subscription.assign_attributes(
          github_repository_full_name: repository.full_name,
          github_repository_url: repository.html_url,
          github_repository_private: repository.private?,
          chatable_type: channel.chatable_type.to_s.presence || "Category",
          created_by_user_id: user.id,
        )
        subscription.save!
      end

      response =
        if created
          DiscourseGithubChat::Renderer.render_subscribe_response(
            repository_name: subscription.github_repository_full_name,
            repository_url: subscription.github_repository_url,
          )
        else
          DiscourseGithubChat::Renderer.render_already_subscribed_response(
            repository_name: subscription.github_repository_full_name,
            repository_url: subscription.github_repository_url,
          )
        end
      respond(channel.id, response_key, response)
    end

    def unsubscribe(repository_full_name, channel, response_key)
      subscription =
        DiscourseGithubChat::Subscription
          .where(chat_channel_id: channel.id)
          .where(
            "LOWER(github_repository_full_name) = ?",
            repository_full_name.downcase,
          )
          .first

      unless subscription
        respond(
          channel.id,
          response_key,
          DiscourseGithubChat::Renderer.render_not_subscribed_response(
            repository_name: repository_full_name,
          ),
        )
        return
      end

      name = subscription.github_repository_full_name
      url = subscription.github_repository_url
      subscription.destroy!
      respond(
        channel.id,
        response_key,
        DiscourseGithubChat::Renderer.render_unsubscribe_response(
          repository_name: name,
          repository_url: url,
        ),
      )
    end

    def respond(channel_id, key, body)
      DiscourseGithubChat::ChatPoster.post(
        channel_id: channel_id,
        body: body,
        idempotency_key: key,
      )
    rescue DiscourseGithubChat::ChatPoster::PermanentError => e
      Rails.logger.warn("[discourse-github-chat] could not post response: #{e.message}")
    end
  end
end
