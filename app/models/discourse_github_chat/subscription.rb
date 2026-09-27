# frozen_string_literal: true

module DiscourseGithubChat
  class Subscription < ActiveRecord::Base
    self.table_name = "discourse_github_chat_subscriptions"

    belongs_to :chat_channel,
               class_name: "::Chat::Channel",
               foreign_key: :chat_channel_id,
               optional: true
    has_many :github_notifications,
             class_name: "::DiscourseGithubChat::GithubNotification",
             foreign_key: :subscription_id,
             dependent: :delete_all

    validates :github_repository_id, presence: true, uniqueness: { scope: :chat_channel_id }
    validates :chat_channel_id, presence: true
    validates :github_repository_full_name, presence: true, length: { maximum: 255 }
    validates :github_repository_url, presence: true, length: { maximum: 2_048 }

    scope :for_repository, ->(repository_id) { where(github_repository_id: repository_id) }
    scope :for_channel, ->(channel_id) { where(chat_channel_id: channel_id) }
  end
end
