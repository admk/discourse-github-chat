# frozen_string_literal: true

module Jobs
  class DeliverDiscourseGithubChatNotification < ::Jobs::Base
    sidekiq_options queue: "default", retry: false

    def execute(args)
      notification_id = args[:notification_id] || args["notification_id"]
      return if notification_id.blank?

      notification = DiscourseGithubChat::GithubNotification.find_by(id: notification_id)
      return if notification.nil?

      claimed = false
      notification.with_lock do
        next if notification.sent? || notification.canceled? || notification.failed?
        if notification.processing? && notification.processing_at.present? &&
             notification.processing_at > 10.minutes.ago
          next
        end
        if notification.pending? && notification.next_attempt_at.present? &&
             notification.next_attempt_at > Time.zone.now
          next
        end

        notification.update!(
          status: "processing",
          attempts: notification.attempts.to_i + 1,
          processing_at: Time.zone.now,
          next_attempt_at: nil,
          last_error: nil,
        )
        claimed = true
      end
      return unless claimed

      deliver(notification)
    rescue StandardError => e
      handle_failure(notification, e)
    end

    private

    def deliver(notification)
      unless SiteSetting.discourse_github_chat_enabled?
        raise "The GitHub Chat plugin is disabled"
      end
      unless defined?(::Chat::Channel) && SiteSetting.chat_enabled?
        raise "Chat is not available"
      end

      subscription = DiscourseGithubChat::Subscription.find_by(id: notification.subscription_id)
      if subscription.nil?
        cancel(notification, "The channel subscription no longer exists")
        return
      end

      if subscription.github_repository_private? &&
           !DiscourseGithubChat::Configuration.allow_private_repositories?
        cancel(notification, "Private GitHub repositories are disabled")
        return
      end

      channel = ::Chat::Channel.find_by(id: notification.chat_channel_id)
      unless DiscourseGithubChat::ChannelPolicy.allowed?(channel)
        cancel(notification, "The Chat channel is no longer available")
        return
      end

      DiscourseGithubChat::ChatPoster.post(
        channel_id: channel.id,
        body: notification.body,
        idempotency_key: notification.dedupe_key,
      )

      notification.with_lock do
        notification.update!(
          status: "sent",
          sent_at: Time.zone.now,
          processing_at: nil,
          next_attempt_at: nil,
          last_error: nil,
        )
      end
    end

    def cancel(notification, reason)
      notification.with_lock do
        notification.update!(
          status: "canceled",
          processing_at: nil,
          next_attempt_at: nil,
          last_error: reason.to_s.first(1_000),
        )
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def handle_failure(notification, error)
      return if notification.nil?

      notification.reload
      return if notification.sent? || notification.canceled? || notification.failed?

      permanent = error.is_a?(DiscourseGithubChat::ChatPoster::PermanentError)
      max_attempts = DiscourseGithubChat::Configuration.max_delivery_attempts
      attempts = notification.attempts.to_i
      message = "#{error.class}: #{error.message}".first(1_000)

      if !permanent && attempts < max_attempts
        delay = [2**[attempts - 1, 8].min, 300].min
        notification.update!(
          status: "pending",
          processing_at: nil,
          next_attempt_at: Time.zone.now + delay.seconds,
          last_error: message,
        )
        Jobs.enqueue_in(
          delay.seconds,
          self.class,
          notification_id: notification.id,
        )
      else
        notification.update!(
          status: "failed",
          processing_at: nil,
          next_attempt_at: nil,
          last_error: message,
        )
      end

      Rails.logger.warn("[discourse-github-chat] notification #{notification.id} failed: #{message}")
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end
end
