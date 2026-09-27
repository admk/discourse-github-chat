# frozen_string_literal: true

module DiscourseGithubChat
  module ChatPoster
    MESSAGE_KEY_FIELD = "discourse_github_chat_delivery_key"

    class PermanentError < StandardError
    end

    module_function

    def bot_user
      username = Configuration.bot_username
      User.find_by(username_lower: username.downcase) || Discourse.system_user
    end

    def message_exists?(channel_id, idempotency_key)
      return false unless defined?(::Chat::MessageCustomField) && defined?(::Chat::Message)

      Chat::MessageCustomField
        .joins("INNER JOIN chat_messages ON chat_messages.id = chat_message_custom_fields.message_id")
        .where(
          name: MESSAGE_KEY_FIELD,
          value: idempotency_key,
          chat_messages: {
            chat_channel_id: channel_id,
            deleted_at: nil,
          },
        )
        .exists?
    end

    def post(channel_id:, body:, idempotency_key:)
      raise PermanentError, "Chat is not available" unless defined?(::ChatSDK::Message)
      raise PermanentError, "Chat is disabled" unless SiteSetting.chat_enabled?
      raise PermanentError, "A notification key is required" if idempotency_key.blank?

      channel = ::Chat::Channel.find_by(id: channel_id)
      raise PermanentError, "Chat channel #{channel_id} was not found" if channel.nil?
      unless channel.respond_to?(:status) && channel.status.to_s == "open"
        raise PermanentError, "Chat channel #{channel_id} is not open"
      end

      return existing_message(channel_id, idempotency_key) if message_exists?(channel_id, idempotency_key)

      bot = bot_user
      restricted = channel.respond_to?(:read_restricted?) && channel.read_restricted?
      membership = channel.membership_for(bot) if channel.respond_to?(:membership_for)
      if restricted && membership.nil?
        raise PermanentError,
              "The GitHub bot must be invited to the private Chat channel before it can post"
      end
      if !restricted && !Configuration.allow_public_channel_join? && membership.nil?
        raise PermanentError,
              "The GitHub bot must be a member of the public Chat channel before it can post"
      end

      return existing_message(channel_id, idempotency_key) if message_exists?(channel_id, idempotency_key)

      enforce_membership = !restricted && Configuration.allow_public_channel_join?

      message = nil
      ActiveRecord::Base.transaction do
        existing = existing_message(channel_id, idempotency_key)
        if existing
          message = existing
          next
        end

        message = ::ChatSDK::Message.create(
          raw: normalized_body(body),
          channel_id: channel.id,
          guardian: bot.guardian,
          enforce_membership: enforce_membership,
        )
        message.upsert_custom_fields(MESSAGE_KEY_FIELD => idempotency_key)
      end
      message
    end

    def normalized_body(body)
      value = body.to_s
      maximum = SiteSetting.chat_maximum_message_length.to_s.to_i
      return value if maximum <= 0 || value.length <= maximum

      suffix = "\n\n_Notification truncated._"
      return value[0, maximum] if maximum <= suffix.length

      value[0, maximum - suffix.length] + suffix
    end

    def existing_message(channel_id, idempotency_key)
      return unless defined?(::Chat::MessageCustomField) && defined?(::Chat::Message)

      field =
        Chat::MessageCustomField
          .joins("INNER JOIN chat_messages ON chat_messages.id = chat_message_custom_fields.message_id")
          .where(
            name: MESSAGE_KEY_FIELD,
            value: idempotency_key,
            chat_messages: {
              chat_channel_id: channel_id,
              deleted_at: nil,
            },
          )
          .first
      field&.message
    end
  end
end
