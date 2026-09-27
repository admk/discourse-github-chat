# frozen_string_literal: true

class CreateDiscourseGithubChatTables < ActiveRecord::Migration[8.0]
  def change
    create_table :discourse_github_chat_subscriptions do |t|
      t.bigint :github_repository_id, null: false
      t.string :github_repository_full_name, null: false, limit: 255
      t.string :github_repository_url, null: false, limit: 2_048
      t.boolean :github_repository_private, null: false, default: false
      t.bigint :chat_channel_id, null: false
      t.string :chatable_type, null: false, limit: 100, default: "Category"
      t.integer :created_by_user_id
      t.timestamps null: false
    end

    add_index :discourse_github_chat_subscriptions,
              %i[github_repository_id chat_channel_id],
              unique: true,
              name: "idx_dgcc_subscriptions_repository_channel"
    add_index :discourse_github_chat_subscriptions,
              :chat_channel_id,
              name: "idx_dgcc_subscriptions_channel"
    add_index :discourse_github_chat_subscriptions,
              :github_repository_id,
              name: "idx_dgcc_subscriptions_repository"

    create_table :discourse_github_chat_installations do |t|
      t.bigint :github_installation_id, null: false
      t.string :account_login, limit: 255
      t.string :account_type, limit: 64
      t.datetime :suspended_at
      t.datetime :last_event_at
      t.timestamps null: false
    end

    add_index :discourse_github_chat_installations,
              :github_installation_id,
              unique: true,
              name: "idx_dgcc_installations_github_installation"

    create_table :discourse_github_chat_deliveries do |t|
      t.string :delivery_id, null: false, limit: 255
      t.string :event_type, null: false, limit: 64
      t.string :event_key, null: false, limit: 250
      t.string :payload_sha256, null: false, limit: 64
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, limit: 32, default: "queued"
      t.text :last_error
      t.datetime :processing_at
      t.datetime :processed_at
      t.timestamps null: false
    end

    add_index :discourse_github_chat_deliveries,
              :delivery_id,
              unique: true,
              name: "idx_dgcc_deliveries_delivery_id"
    add_index :discourse_github_chat_deliveries,
              :status,
              name: "idx_dgcc_deliveries_status"
    add_index :discourse_github_chat_deliveries,
              :event_key,
              name: "idx_dgcc_deliveries_event_key"

    create_table :discourse_github_chat_notifications do |t|
      t.string :dedupe_key, null: false, limit: 255
      t.bigint :github_delivery_id, null: false
      t.bigint :subscription_id, null: false
      t.bigint :chat_channel_id, null: false
      t.bigint :github_repository_id, null: false
      t.text :body, null: false
      t.jsonb :metadata, null: false, default: {}
      t.string :status, null: false, limit: 32, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :processing_at
      t.datetime :next_attempt_at
      t.datetime :sent_at
      t.text :last_error
      t.timestamps null: false
    end

    add_index :discourse_github_chat_notifications,
              :dedupe_key,
              unique: true,
              name: "idx_dgcc_notifications_dedupe_key"
    add_index :discourse_github_chat_notifications,
              %i[status next_attempt_at],
              name: "idx_dgcc_notifications_status_next_attempt"
    add_index :discourse_github_chat_notifications,
              :chat_channel_id,
              name: "idx_dgcc_notifications_channel"
    add_index :discourse_github_chat_notifications,
              :subscription_id,
              name: "idx_dgcc_notifications_subscription"
  end
end
