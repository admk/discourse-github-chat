# frozen_string_literal: true

module DiscourseGithubChat
  class GithubDelivery < ActiveRecord::Base
    self.table_name = "discourse_github_chat_deliveries"

    STATUSES = %w[queued processing processed ignored failed].freeze

    has_many :github_notifications,
             class_name: "::DiscourseGithubChat::GithubNotification",
             foreign_key: :github_delivery_id,
             dependent: :delete_all

    validates :delivery_id, presence: true, uniqueness: true
    validates :event_type, presence: true
    validates :event_key, presence: true
    validates :payload_sha256, presence: true, length: { is: 64 }
    validates :status, inclusion: { in: STATUSES }

    scope :queued, -> { where(status: "queued") }
    scope :stale_processing, -> { where(status: "processing").where("processing_at < ?", 10.minutes.ago) }

    STATUSES.each do |status|
      define_method("#{status}?") { self.status == status }
    end
  end
end
