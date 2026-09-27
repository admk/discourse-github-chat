# frozen_string_literal: true

module DiscourseGithubChat
  class CommandMessageObserver
    def initialize(message, channel, user)
      @message = message
      @channel = channel
      @user = user
    end

    def enqueue
      return if @message.nil? || @message.id.blank?
      return if @user.nil?
      return if @user.respond_to?(:bot?) && @user.bot?
      return unless @message.respond_to?(:message)
      return unless @message.message.to_s.match?(/\A\/github(?:[ \t]|\z)/)
      return if @user.respond_to?(:id) && @user.id == ChatPoster.bot_user.id

      Jobs.enqueue(
        Jobs::ProcessDiscourseGithubChatCommand,
        chat_message_id: @message.id,
      )
    rescue StandardError => e
      Rails.logger.warn("[discourse-github-chat] could not enqueue command: #{e.class}: #{e.message}")
    end
  end
end
