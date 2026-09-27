# frozen_string_literal: true

RSpec.describe DiscourseGithubChat::Renderer do
  describe ".render_issue_event" do
    it "renders an issue event with a link and actor" do
      body = described_class.render_issue_event(
        {
          "repository" => {
            "id" => 1,
            "full_name" => "acme/widgets",
            "html_url" => "https://github.com/acme/widgets",
            "private" => false,
          },
          "issue" => {
            "number" => 7,
            "title" => "Broken widget",
            "html_url" => "https://github.com/acme/widgets/issues/7",
            "user" => { "login" => "alice" },
          },
        },
        "opened",
      )

      expect(body).to include("GitHub issue opened")
      expect(body).to include("acme/widgets")
      expect(body).to include("#7 Broken widget by alice")
      expect(body).to include("https://github.com/acme/widgets/issues/7")
    end

    it "escapes event text that could become Markdown" do
      body = described_class.render_issue_event(
        {
          "repository" => { "full_name" => "acme/widgets", "html_url" => "https://github.com/acme/widgets" },
          "issue" => { "number" => 1, "title" => "[x] @alice `code`", "html_url" => "https://github.com/acme/widgets/issues/1" },
        },
        "closed",
      )

      expect(body).to include("\\[x\\] \\@alice \\`code\\`")
    end
  end

  describe ".render_push_event" do
    it "renders one summary and caps the displayed commits" do
      body = described_class.render_push_event(
        {
          "repository" => { "full_name" => "acme/widgets", "html_url" => "https://github.com/acme/widgets" },
          "ref" => "refs/heads/main",
          "size" => 3,
          "commits" => [
            { "id" => "aaaaaaaa", "url" => "https://github.com/acme/widgets/commit/aaaaaaaa", "message" => "First\nbody", "author" => { "name" => "Alice" } },
            { "id" => "bbbbbbbb", "url" => "https://github.com/acme/widgets/commit/bbbbbbbb", "message" => "Second", "author" => { "username" => "bob" } },
            { "id" => "cccccccc", "url" => "https://github.com/acme/widgets/commit/cccccccc", "message" => "Third", "author" => { "name" => "Carol" } },
          ],
        },
        max_commits: 2,
      )

      expect(body).to include("3 new commits")
      expect(body).to include("First")
      expect(body).to include("Second")
      expect(body).not_to include("Third")
      expect(body).to include("1 more commit")
    end

    it "does not render deleted branch pushes as commits" do
      body = described_class.render_push_event(
        {
          "repository" => { "full_name" => "acme/widgets", "html_url" => "https://github.com/acme/widgets" },
          "ref" => "refs/heads/main",
          "after" => "0000000000000000000000000000000000000000",
          "deleted" => true,
        },
        max_commits: 10,
      )

      expect(body).to include("0 new commits")
      expect(body).to include("No commit details")
    end
  end

  describe ".render_installation_required_response" do
    it "includes a safe installation link and retry instruction" do
      body = described_class.render_installation_required_response(
        install_url: "https://github.com/apps/example/installations/new",
      )

      expect(body).to include("GitHub App installation is required")
      expect(body).to include("https://github.com/apps/example/installations/new")
      expect(body).to include("subscribe <owner>/<repo> again")
    end
  end

  describe ".render_usage_response" do
    it "documents slash-only commands" do
      expect(described_class.render_usage_response).to include("/github subscribe <owner>/<repo>")
      expect(described_class.render_usage_response).not_to include("@github")
      expect(described_class.render_usage_response).not_to include("github_repo_id")
    end
  end
end
