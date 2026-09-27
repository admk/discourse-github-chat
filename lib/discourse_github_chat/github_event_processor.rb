# frozen_string_literal: true

require "digest"

module DiscourseGithubChat
  class GithubEventProcessor
    ISSUE_ACTIONS = %w[opened closed reopened].freeze

    def self.call(github_delivery_id)
      new(github_delivery_id).call
    end

    def initialize(github_delivery_id)
      @github_delivery_id = github_delivery_id.to_i
    end

    def call
      return unless SiteSetting.discourse_github_chat_enabled?

      delivery = DiscourseGithubChat::GithubDelivery.find_by(id: @github_delivery_id)
      return if delivery.nil?
      return if %w[processed ignored failed].include?(delivery.status)

      notification_ids = []
      DiscourseGithubChat::GithubDelivery.transaction do
        delivery.lock!
        return if %w[processed ignored failed].include?(delivery.status)

        delivery.update!(
          status: "processing",
          processing_at: Time.zone.now,
          last_error: nil,
        )

        unless chat_available?
          delivery.update!(status: "queued", processing_at: nil)
          next
        end

        payload = delivery.payload.is_a?(Hash) ? delivery.payload : {}
        repository = payload["repository"].is_a?(Hash) ? payload["repository"] : {}
        repository_id = positive_integer(repository["id"])
        if repository_id.nil?
          delivery.update!(status: "ignored", processed_at: Time.zone.now, processing_at: nil)
          next
        end

        notification_ids.concat(build_notifications(delivery, payload, repository_id))
        delivery.update!(
          status: "processed",
          processed_at: Time.zone.now,
          processing_at: nil,
          last_error: nil,
        )
      end

      enqueue_notifications(notification_ids)
    rescue StandardError => e
      delivery&.update_columns(
        status: "queued",
        processing_at: nil,
        last_error: e.message.to_s.first(1_000),
        updated_at: Time.zone.now,
      )
      raise
    end

    private

    def build_notifications(delivery, payload, repository_id)
      body = notification_body(delivery.event_type, payload)
      return [] if body.blank?

      ids = []
      subscriptions = DiscourseGithubChat::Subscription.where(
        github_repository_id: repository_id,
      ).includes(:chat_channel)

      subscriptions.each do |subscription|
        channel = subscription.chat_channel
        next unless DiscourseGithubChat::ChannelPolicy.allowed?(channel)
        next if private_repository?(payload, subscription) && !Configuration.allow_private_repositories?

        dedupe_key = "github:#{Digest::SHA256.hexdigest("#{delivery.event_key}:#{subscription.id}")}"
        notification =
          DiscourseGithubChat::GithubNotification.create_or_find_by!(dedupe_key: dedupe_key) do |record|
            record.github_delivery_id = delivery.id
            record.subscription_id = subscription.id
            record.chat_channel_id = subscription.chat_channel_id
            record.github_repository_id = repository_id
            record.body = body
            record.metadata = {
              "event_type" => delivery.event_type,
              "event_key" => delivery.event_key,
              "delivery_id" => delivery.delivery_id,
            }
            record.status = "pending"
          end

        ids << notification.id if notification.pending?
      end
      ids
    end

    def notification_body(event_type, payload)
      case event_type
      when "issues"
        action = payload["action"].to_s
        return unless ISSUE_ACTIONS.include?(action)

        DiscourseGithubChat::Renderer.render_issue_event(payload, action)
      when "push"
        return unless valid_push?(payload)

        DiscourseGithubChat::Renderer.render_push_event(
          payload,
          max_commits: Configuration.max_commits_in_summary,
        )
      end
    end

    def valid_push?(payload)
      return false if payload["deleted"] == true

      after = payload["after"].to_s
      return false if after.present? && after.match?(/\A0+\z/)

      commits = payload["commits"]
      head_commit = payload["head_commit"]
      (commits.is_a?(Array) && commits.any?) ||
        (head_commit.is_a?(Hash) && !head_commit.empty?)
    end

    def private_repository?(payload, subscription)
      repository = payload["repository"].is_a?(Hash) ? payload["repository"] : {}
      repository["private"] == true || subscription.github_repository_private == true
    end

    def chat_available?
      defined?(::Chat::Channel) && SiteSetting.chat_enabled?
    end

    def enqueue_notifications(ids)
      return if ids.blank?

      DiscourseGithubChat::GithubNotification
        .where(id: ids, status: "pending")
        .find_each do |notification|
          Jobs.enqueue(
            Jobs::DeliverDiscourseGithubChatNotification,
            notification_id: notification.id,
          )
        end
    end

    def positive_integer(value)
      integer = Integer(value, exception: false)
      integer if integer&.positive?
    end
  end
end
