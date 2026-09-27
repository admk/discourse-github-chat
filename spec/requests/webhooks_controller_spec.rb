# frozen_string_literal: true

RSpec.describe DiscourseGithubChat::WebhooksController do
  let(:secret) { "github-chat-spec-secret" }
  let(:payload) do
    {
      repository: {
        id: 42,
        full_name: "acme/widgets",
        html_url: "https://github.com/acme/widgets",
        private: false,
      },
      action: "opened",
      issue: {
        id: 100,
        number: 7,
        title: "An issue",
        html_url: "https://github.com/acme/widgets/issues/7",
        user: { login: "alice" },
      },
    }
  end

  before do
    SiteSetting.discourse_github_chat_enabled = true
    SiteSetting.discourse_github_chat_github_webhook_secret = secret
  end

  after do
    DiscourseGithubChat::GithubDelivery.where("delivery_id LIKE ?", "github-chat-spec-%").delete_all
  end

  def signed_body(value = payload)
    body = value.to_json
    [body, "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"]
  end

  def post_webhook(body:, signature:, delivery_id: "github-chat-spec-#{SecureRandom.hex(4)}", event: "issues")
    post(
      "/github-chat/webhooks/github",
      params: body,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "X-GitHub-Event" => event,
        "X-GitHub-Delivery" => delivery_id,
        "X-Hub-Signature-256" => signature,
      },
    )
  end

  it "rejects an invalid signature" do
    body, = signed_body

    post_webhook(body: body, signature: "sha256=#{"0" * 64}")

    expect(response.status).to eq(403)
  end

  it "rejects a non-object JSON body" do
    body = "[]"
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"

    post_webhook(body: body, signature: signature)

    expect(response.status).to eq(400)
  end

  it "accepts and queues a valid issue delivery" do
    body, signature = signed_body
    delivery_id = "github-chat-spec-#{SecureRandom.hex(4)}"

    expect_enqueued_with(
      job: Jobs::ProcessDiscourseGithubChatDelivery,
      args: { github_delivery_id: kind_of(Integer) },
    ) do
      post_webhook(body: body, signature: signature, delivery_id: delivery_id)
    end

    expect(response.status).to eq(202)
    expect(DiscourseGithubChat::GithubDelivery.find_by(delivery_id: delivery_id)).to be_present
  end

  it "deduplicates a replayed delivery" do
    body, signature = signed_body
    delivery_id = "github-chat-spec-#{SecureRandom.hex(4)}"

    post_webhook(body: body, signature: signature, delivery_id: delivery_id)
    post_webhook(body: body, signature: signature, delivery_id: delivery_id)

    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)["duplicate"]).to eq(true)
    expect(DiscourseGithubChat::GithubDelivery.where(delivery_id: delivery_id).count).to eq(1)
  end

  it "rejects reuse of a delivery ID with a different payload" do
    first_body, first_signature = signed_body
    delivery_id = "github-chat-spec-#{SecureRandom.hex(4)}"
    post_webhook(body: first_body, signature: first_signature, delivery_id: delivery_id)

    second_payload = payload.deep_merge(issue: { title: "Changed" })
    second_body, second_signature = signed_body(second_payload)
    post_webhook(body: second_body, signature: second_signature, delivery_id: delivery_id)

    expect(response.status).to eq(409)
  end
end
