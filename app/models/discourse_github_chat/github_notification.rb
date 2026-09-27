# frozen_string_literal: true

module DiscourseGithubChat
  class GithubNotification < ActiveRecord::Base
    self.table_name = "discourse_github_chat_notifications"

    STATUSES = %w[pending processing sent canceled failed].freeze

    belongs_to :github_delivery,
               class_name: "::DiscourseGithubChat::GithubDelivery",
               foreign_key: :github_delivery_id,
               optional: true
    belongs_to :subscription,
               class_name: "::DiscourseGithubChat::Subscription",
               foreign_key: :subscription_id,
               optional: true

    validates :dedupe_key, presence: true, uniqueness: true
    validates :github_delivery_id, :subscription_id, :chat_channel_id, :github_repository_id, presence: true
    validates :body, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :pending, -> { where(status: "pending") }
    scope :due, -> { where(status: "pending").where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.zone.now) }
    scope :stale_processing, -> { where(status: "processing").where("processing_at < ?", 10.minutes.ago) }

    STATUSES.each do |status|
      define_method("#{status}?") { self.status == status }
    end
  end
end
