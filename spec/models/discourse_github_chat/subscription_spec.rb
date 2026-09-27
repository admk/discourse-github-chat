# frozen_string_literal: true

RSpec.describe DiscourseGithubChat::Subscription do
  fab!(:user)
  fab!(:channel) { Fabricate(:category_channel) }

  it "allows only one subscription per repository and channel" do
    described_class.create!(
      github_repository_id: 42,
      github_repository_full_name: "acme/widgets",
      github_repository_url: "https://github.com/acme/widgets",
      chat_channel_id: channel.id,
      created_by_user_id: user.id,
    )

    duplicate =
      described_class.new(
        github_repository_id: 42,
        github_repository_full_name: "acme/widgets",
        github_repository_url: "https://github.com/acme/widgets",
        chat_channel_id: channel.id,
      )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:github_repository_id]).to be_present
  end
end
