# frozen_string_literal: true

RSpec.describe Jobs::ProcessDiscourseGithubChatCommand do
  fab!(:user)
  fab!(:channel) { Fabricate(:category_channel) }

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.discourse_github_chat_enabled = true
    SiteSetting.discourse_github_chat_bot_username = "system"
    SiteSetting.discourse_github_chat_allow_public_channel_join = true
  end

  it "responds to a slash command without requiring a mention" do
    message =
      Fabricate(
        :chat_message,
        use_service: true,
        chat_channel: channel,
        user: user,
        message: "/github help extra",
      )

    described_class.new.execute(chat_message_id: message.id)

    response = channel.chat_messages.where("message LIKE ?", "Usage: `/github%").last
    expect(response).to be_present
    expect(response.user).to eq(Discourse.system_user)
  end

  it "responds to /github and /github help with the command list" do
    message =
      Fabricate(
        :chat_message,
        use_service: true,
        chat_channel: channel,
        user: user,
        message: "/github",
      )

    described_class.new.execute(chat_message_id: message.id)

    response = channel.chat_messages.where("message LIKE ?", "**GitHub Chat commands**%").last
    expect(response).to be_present
    expect(response.message).to include("/github subscribe <owner>/<repo>")
  end

  it "does not process a command that still has a bot mention" do
    message =
      Fabricate(
        :chat_message,
        use_service: true,
        chat_channel: channel,
        user: user,
        message: "@system /github",
      )

    described_class.new.execute(chat_message_id: message.id)

    expect(channel.chat_messages.where("message LIKE ?", "Usage: `/github%")).to be_empty
  end
end
