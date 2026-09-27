# frozen_string_literal: true

RSpec.describe DiscourseGithubChat::CommandParser do
  describe ".parse" do
    it "parses the bare slash command as help" do
      result = described_class.parse("/github")

      expect(result).to be_help
      expect(result.command.action).to eq("help")
    end

    it "parses the explicit help command" do
      result = described_class.parse("/github help")

      expect(result).to be_help
    end

    it "parses a slash-only subscribe command" do
      result = described_class.parse("/github subscribe acme/widgets")

      expect(result.invalid).to eq(false)
      expect(result.command.action).to eq("subscribe")
      expect(result.command.repository_full_name).to eq("acme/widgets")
    end

    it "parses unsubscribe" do
      result = described_class.parse("/github unsubscribe acme/widgets")

      expect(result.command.action).to eq("unsubscribe")
      expect(result.command.repository_full_name).to eq("acme/widgets")
    end

    it "does not require a bot mention" do
      expect(described_class.parse("@github /github subscribe acme/widgets").command?).to eq(false)
    end

    it "does not match commands embedded in quotes, code, or prose" do
      expect(described_class.parse("> /github subscribe acme/widgets").command?).to eq(false)
      expect(described_class.parse("```\n/github subscribe acme/widgets\n```").command?).to eq(false)
      expect(described_class.parse("please /github subscribe acme/widgets").command?).to eq(false)
    end

    it "marks malformed command messages for a usage response" do
      [
        "/github help extra",
        "/github subscribe",
        "/github subscribe acme",
        "/github subscribe acme/widgets/extra",
        "/github subscribe acme/widgets extra",
        "/github subscribe 123456789",
        "/github subscribe https://github.com/acme/widgets",
        "/github subscribe acme/..",
      ].each do |message|
        result = described_class.parse(message)
        expect(result).to be_invalid
        expect(result.command).to be_nil
      end
    end

    it "ignores unrelated messages" do
      expect(described_class.parse("hello").command?).to eq(false)
      expect(described_class.parse("/githubish subscribe acme/widgets").command?).to eq(false)
    end
  end
end
