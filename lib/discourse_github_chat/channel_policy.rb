# frozen_string_literal: true

module DiscourseGithubChat
  module ChannelPolicy
    module_function

    def allowed?(channel)
      return false if channel.nil?
      return false if channel.respond_to?(:deleted_at) && channel.deleted_at.present?
      return false unless channel.respond_to?(:status)
      return false unless channel.status.to_s == "open"

      chatable_type = channel.respond_to?(:chatable_type) ? channel.chatable_type.to_s : ""
      case chatable_type
      when "Category", "CategoryChannel"
        allowed_channel_id?(channel.id)
      when "DirectMessage", "DirectMessageChannel"
        Configuration.allow_direct_message_channels? && allowed_channel_id?(channel.id)
      else
        false
      end
    end

    def allowed_channel_id?(channel_id)
      allowed = Configuration.allowed_channel_ids
      allowed.empty? || allowed.include?(channel_id.to_i)
    end
  end
end
