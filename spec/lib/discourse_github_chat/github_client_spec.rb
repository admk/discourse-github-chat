# frozen_string_literal: true

RSpec.describe DiscourseGithubChat::GitHubClient do
  let(:private_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:installation_id) { 9876 }
  let(:responses) { [] }
  let(:http) do
    lambda do |method:, uri:, headers:, body:|
      expect(uri.host).to eq("api.github.com")
      expect(headers["Authorization"]).to start_with("Bearer ") if method == :get
      responses.shift || { status: 500, headers: {}, body: "{}" }
    end
  end
  let(:client) do
    described_class.new(
      app_id: 1234,
      private_key: private_key.to_pem,
      http: http,
      clock: -> { 1_700_000_000 },
    )
  end

  before do
    described_class.clear_token_cache
    SiteSetting.discourse_github_chat_github_installation_id = installation_id
  end

  after { described_class.clear_token_cache }

  it "creates a GitHub App JWT-backed installation token" do
    responses << {
      status: 201,
      headers: {},
      body: {
        token: "ghs_test",
        expires_at: "2023-11-14T22:20:00Z",
      }.to_json,
    }

    expect(client.send(:installation_token, installation_id)).to eq("ghs_test")
  end

  it "looks up a repository through the official installation repositories endpoint" do
    responses << {
      status: 201,
      headers: {},
      body: { token: "ghs_test", expires_at: "2023-11-14T22:20:00Z" }.to_json,
    }
    responses << {
      status: 200,
      headers: {},
      body: {
        repositories: [
          {
            id: 42,
            full_name: "acme/widgets",
            html_url: "https://github.com/acme/widgets",
            private: false,
          },
        ],
      }.to_json,
    }

    repository = client.repository("acme/widgets")

    expect(repository.id).to eq(42)
    expect(repository.full_name).to eq("acme/widgets")
    expect(repository).not_to be_private
  end

  it "discovers and records an installation when the installation webhook is missing" do
    SiteSetting.discourse_github_chat_github_installation_id = ""
    responses << {
      status: 200,
      headers: {},
      body: [
        {
          id: 9876,
          account: { login: "acme", type: "Organization" },
        },
      ].to_json,
    }
    responses << {
      status: 201,
      headers: {},
      body: { token: "ghs_test", expires_at: "2023-11-14T22:20:00Z" }.to_json,
    }
    responses << {
      status: 200,
      headers: {},
      body: {
        repositories: [
          {
            id: 42,
            full_name: "acme/widgets",
            html_url: "https://github.com/acme/widgets",
            private: false,
          },
        ],
      }.to_json,
    }

    repository = client.repository("acme/widgets")

    expect(repository.id).to eq(42)
    expect(DiscourseGithubChat::GithubInstallation.find_by(github_installation_id: 9876)).to be_present
  end

  it "derives the App installation URL from the GitHub App metadata" do
    responses << {
      status: 200,
      headers: {},
      body: {
        slug: "example-app",
        html_url: "https://github.com/apps/example-app",
      }.to_json,
    }

    expect(client.app_install_url).to eq(
      "https://github.com/apps/example-app/installations/new",
    )
  end

  it "raises a retryable error for a rate-limited response" do
    responses << {
      status: 429,
      headers: { "retry-after" => "60" },
      body: "{}",
    }

    expect { client.send(:installation_token, installation_id) }.to raise_error(
      DiscourseGithubChat::GitHubError,
    ) { |error| expect(error).to be_retryable }
  end
end
