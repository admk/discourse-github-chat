# frozen_string_literal: true

module Jobs
  class DiscourseGithubChatPeriodicalUpdates < ::Jobs::Scheduled
    every 5.minutes

    def execute(_args = {})
      return unless SiteSetting.discourse_github_chat_enabled?

      DiscourseGithubChat::GithubDelivery
        .stale_processing
        .update_all(
          status: "queued",
          processing_at: nil,
          last_error: "Recovered after a stale processing interval",
          updated_at: Time.zone.now,
        )

      DiscourseGithubChat::GithubDelivery
        .queued
        .order(:id)
        .limit(500)
        .pluck(:id)
        .each do |delivery_id|
          Jobs.enqueue(
            Jobs::ProcessDiscourseGithubChatDelivery,
            github_delivery_id: delivery_id,
          )
        end

      DiscourseGithubChat::GithubNotification
        .stale_processing
        .update_all(
          status: "pending",
          processing_at: nil,
          next_attempt_at: Time.zone.now,
          updated_at: Time.zone.now,
        )

      DiscourseGithubChat::GithubNotification
        .due
        .order(:id)
        .limit(500)
        .pluck(:id)
        .each do |notification_id|
          Jobs.enqueue(
            Jobs::DeliverDiscourseGithubChatNotification,
            notification_id: notification_id,
          )
        end
    end
  end
end
