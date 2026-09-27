# frozen_string_literal: true

# name: discourse-github-chat
# about: Receive GitHub issue and push notifications in Discourse Chat channels.
# meta_topic_id: 0
# version: 0.1.0
# authors: Discourse
# url: https://github.com/discourse/discourse-github-chat
# required_version: 2.7.0

enabled_site_setting :discourse_github_chat_enabled

module ::DiscourseGithubChat
  PLUGIN_NAME = "discourse-github-chat"
end

# The plugin deliberately does not patch Chat::Message::SLASH_COMMAND_PATTERNS.
# /github is a server-side command: the original message remains visible and the
# bot posts its response in the same channel.
after_initialize do
  require_relative "lib/discourse_github_chat/configuration"
  require_relative "lib/discourse_github_chat/command_parser"
  require_relative "lib/discourse_github_chat/renderer"
  require_relative "lib/discourse_github_chat/github_client"
  require_relative "lib/discourse_github_chat/channel_policy"
  require_relative "lib/discourse_github_chat/chat_poster"
  require_relative "lib/discourse_github_chat/webhook_ingest"
  require_relative "lib/discourse_github_chat/github_event_processor"
  require_relative "lib/discourse_github_chat/command_message_observer"

  require_relative "app/models/discourse_github_chat/subscription"
  require_relative "app/models/discourse_github_chat/github_installation"
  require_relative "app/models/discourse_github_chat/github_delivery"
  require_relative "app/models/discourse_github_chat/github_notification"

  require_relative "app/jobs/regular/process_discourse_github_chat_command"
  require_relative "app/jobs/regular/process_discourse_github_chat_delivery"
  require_relative "app/jobs/regular/deliver_discourse_github_chat_notification"
  require_relative "app/jobs/scheduled/discourse_github_chat_periodical_updates"
  require_relative "app/controllers/discourse_github_chat/webhooks_controller"

  Discourse::Application.routes.append do
    post "/github-chat/webhooks/github" => "discourse_github_chat/webhooks#github"
  end

  # The command is slash-only, so raw message processing is sufficient and
  # avoids depending on mention extraction. The observer still ignores bot
  # messages and malformed/quoted commands are filtered by the parser.
  on(:chat_message_created) do |message, channel, user, _data|
    next if !SiteSetting.discourse_github_chat_enabled?

    DiscourseGithubChat::CommandMessageObserver.new(message, channel, user).enqueue
  end
end
