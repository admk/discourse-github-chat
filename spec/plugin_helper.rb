# frozen_string_literal: true

# The notification specs use Chat's public fabricators. Load them explicitly
# when this plugin is selected as the test plugin.
chat_fabricator = Rails.root.join("plugins/chat/spec/fabricators/chat_fabricator.rb")
require chat_fabricator.to_s if chat_fabricator.exist?
