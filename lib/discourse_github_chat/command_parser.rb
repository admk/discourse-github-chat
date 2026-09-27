# frozen_string_literal: true

module DiscourseGithubChat
  module CommandParser
    # GitHub owner logins and repository names are intentionally narrower than
    # arbitrary text. The value is resolved through the App installation before
    # a subscription is created.
    REPOSITORY_FULL_NAME_PATTERN =
      %r{\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}\z}

    Command = Struct.new(:action, :repository_full_name, keyword_init: true)
    Result = Struct.new(:command, :invalid, keyword_init: true) do
      def command?
        !command.nil? || invalid
      end

      def help?
        command&.action == "help"
      end

      def invalid?
        invalid
      end
    end

    module_function

    # Only a complete, unquoted raw message is a command. In particular, this
    # does not match a command inside a quote, a code block, or a sentence.
    def parse(raw)
      text = raw.to_s
      return Result.new(command: nil, invalid: false) unless text.match?(/\A\/github(?:[ \t]|\z)/)

      return help_result if text.match?(/\A\/github[ \t]*\z/) || text.match?(/\A\/github[ \t]+help[ \t]*\z/)

      match = text.match(/\A\/github[ \t]+(subscribe|unsubscribe)[ \t]+([^ \t\r\n]+)[ \t]*\z/)
      return Result.new(command: nil, invalid: true) unless match

      full_name = match[2]
      return Result.new(command: nil, invalid: true) unless valid_repository_full_name?(full_name)

      Result.new(
        command: Command.new(action: match[1], repository_full_name: full_name),
        invalid: false,
      )
    end

    def help_result
      Result.new(
        command: Command.new(action: "help"),
        invalid: false,
      )
    end

    def valid_repository_full_name?(full_name)
      return false unless full_name.is_a?(String)
      return false unless full_name.match?(REPOSITORY_FULL_NAME_PATTERN)

      owner, repository = full_name.split("/", 2)
      repository != "." && repository != ".." && !owner.to_s.empty? && !repository.to_s.empty?
    end
  end
end
