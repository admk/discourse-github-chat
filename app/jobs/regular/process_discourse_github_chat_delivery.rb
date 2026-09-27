# frozen_string_literal: true

module Jobs
  class ProcessDiscourseGithubChatDelivery < ::Jobs::Base
    sidekiq_options queue: "default", retry: 10

    def execute(args)
      delivery_id = args[:github_delivery_id] || args["github_delivery_id"]
      return if delivery_id.blank?

      DiscourseGithubChat::GithubEventProcessor.call(delivery_id)
    end
  end
end
