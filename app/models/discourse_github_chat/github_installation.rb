# frozen_string_literal: true

module DiscourseGithubChat
  class GithubInstallation < ActiveRecord::Base
    self.table_name = "discourse_github_chat_installations"

    validates :github_installation_id, presence: true, uniqueness: true
  end
end
