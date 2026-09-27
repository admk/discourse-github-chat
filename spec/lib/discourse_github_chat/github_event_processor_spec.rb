# frozen_string_literal: true

RSpec.describe DiscourseGithubChat::GithubEventProcessor do
  fab!(:user)
  fab!(:channel) { Fabricate(:category_channel) }
  fab!(:subscription) do
    DiscourseGithubChat::Subscription.create!(
      github_repository_id: 42,
      github_repository_full_name: "acme/widgets",
      github_repository_url: "https://github.com/acme/widgets",
      chat_channel_id: channel.id,
      created_by_user_id: user.id,
    )
  end

  let(:issue_payload) do
    {
      "repository" => {
        "id" => 42,
        "full_name" => "acme/widgets",
        "html_url" => "https://github.com/acme/widgets",
        "private" => false,
      },
      "action" => "opened",
      "issue" => {
        "id" => 100,
        "number" => 7,
        "title" => "An issue",
        "html_url" => "https://github.com/acme/widgets/issues/7",
        "user" => { "login" => "alice" },
      },
    }
  end

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.discourse_github_chat_enabled = true
    SiteSetting.discourse_github_chat_allow_private_repositories = false
  end

  def create_delivery(payload, delivery_id:, event_key:, event_type: "issues")
    DiscourseGithubChat::GithubDelivery.create!(
      delivery_id: delivery_id,
      event_type: event_type,
      event_key: event_key,
      payload_sha256: Digest::SHA256.hexdigest(payload.to_json),
      payload: payload,
    )
  end

  it "creates one notification for an issue event" do
    delivery = create_delivery(
      issue_payload,
      delivery_id: "processor-1",
      event_key: "issues:42:100:opened",
    )

    expect { described_class.call(delivery.id) }.to change(
      DiscourseGithubChat::GithubNotification,
      :count,
    ).by(1)

    notification = DiscourseGithubChat::GithubNotification.last
    expect(notification.body).to include("GitHub issue opened")
    expect(notification.status).to eq("pending")
    expect(delivery.reload.status).to eq("processed")
  end

  it "deduplicates a replay with a different delivery ID" do
    first = create_delivery(
      issue_payload,
      delivery_id: "processor-2",
      event_key: "issues:42:100:opened",
    )
    second = create_delivery(
      issue_payload,
      delivery_id: "processor-3",
      event_key: "issues:42:100:opened",
    )

    described_class.call(first.id)
    expect { described_class.call(second.id) }.not_to change(
      DiscourseGithubChat::GithubNotification,
      :count,
    )
  end

  it "creates one summary notification for a push" do
    payload = {
      "repository" => {
        "id" => 42,
        "full_name" => "acme/widgets",
        "html_url" => "https://github.com/acme/widgets",
        "private" => false,
      },
      "ref" => "refs/heads/main",
      "after" => "abc123",
      "size" => 1,
      "commits" => [
        {
          "id" => "abc123",
          "url" => "https://api.github.com/repos/acme/widgets/commits/abc123",
          "message" => "Improve widgets",
          "author" => { "name" => "Alice" },
        },
      ],
    }
    delivery = create_delivery(
      payload,
      delivery_id: "processor-push",
      event_key: "push:42:refs/heads/main:abc123",
      event_type: "push",
    )

    expect { described_class.call(delivery.id) }.to change(
      DiscourseGithubChat::GithubNotification,
      :count,
    ).by(1)

    notification = DiscourseGithubChat::GithubNotification.last
    expect(notification.body).to include("GitHub push")
    expect(notification.body).to include("Improve widgets")
    expect(notification.body).to include("https://github.com/acme/widgets/commit/abc123")
  end

  it "does not expose private repository events by default" do
    payload = issue_payload.deep_merge("repository" => { "private" => true })
    delivery = create_delivery(
      payload,
      delivery_id: "processor-private",
      event_key: "issues:42:100:opened",
    )

    expect { described_class.call(delivery.id) }.not_to change(
      DiscourseGithubChat::GithubNotification,
      :count,
    )
    expect(delivery.reload.status).to eq("processed")
  end
end
