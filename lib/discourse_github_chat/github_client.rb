# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"
require "jwt"

module DiscourseGithubChat
  class GitHubError < StandardError
    attr_reader :status, :retryable

    def initialize(message = nil, status: nil, retryable: false)
      @status = status
      @retryable = retryable
      super(message || "GitHub API request failed#{status ? " (status #{status})" : ""}")
    end

    def retryable?
      retryable
    end
  end

  class GitHubNotConfigured < GitHubError
  end

  class GitHubInstallationNotConfigured < GitHubNotConfigured
  end

  class GitHubRepositoryNotFound < GitHubError
  end

  class GitHubTransportError < GitHubError
    def initialize(message)
      super(message, retryable: true)
    end
  end

  class GitHubClient
    API_VERSION = "2022-11-28"
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024
    TOKEN_EXPIRY_BUFFER = 60
    MAX_REPOSITORY_PAGES = 100

    Repository = Struct.new(:id, :full_name, :html_url, :private_repo, keyword_init: true) do
      def private?
        private_repo == true
      end
    end

    Token = Struct.new(:value, :expires_at, keyword_init: true)

    @token_cache = {}
    @token_cache_mutex = Mutex.new

    class << self
      attr_reader :token_cache, :token_cache_mutex

      def clear_token_cache(installation_id = nil)
        @token_cache_mutex.synchronize do
          if installation_id
            @token_cache.delete(installation_id.to_i)
          else
            @token_cache.clear
          end
        end
      end
    end

    def initialize(
      app_id: Configuration.github_app_id,
      private_key: Configuration.github_private_key,
      api_url: Configuration.github_api_url,
      http: nil,
      clock: -> { Time.now.to_i }
    )
      @app_id = app_id
      @private_key = private_key
      @api_url = api_url.to_s.chomp("/")
      @http = http
      @clock = clock
    end

    def repository(repository_full_name)
      full_name = repository_full_name.to_s.strip
      unless CommandParser.valid_repository_full_name?(full_name)
        raise GitHubRepositoryNotFound,
              "A GitHub repository must be specified as owner/repository"
      end

      installation_ids.each do |installation_id|
        begin
          found = find_installation_repository(installation_id, full_name)
          return found if found
        rescue GitHubTransportError
          raise
        rescue GitHubError => e
          raise if e.retryable?

          next
        end
      end

      raise GitHubRepositoryNotFound,
            "GitHub repository #{full_name} was not found or the GitHub App cannot access it"
    end

    def app_install_url
      configured = Configuration.github_app_install_url
      return configured unless configured.empty?

      body = request(:get, "/app", token: app_jwt)
      body = {} unless body.is_a?(Hash)
      html_url = body["html_url"].to_s.chomp("/")
      return "#{html_url}/installations/new" unless html_url.empty?

      slug = body["slug"].to_s
      return "https://github.com/apps/#{slug}/installations/new" unless slug.empty?

      "https://github.com/apps"
    rescue StandardError
      configured = Configuration.github_app_install_url
      configured.empty? ? "https://github.com/apps" : configured
    end

    def installation_token(installation_id)
      installation_id = installation_id.to_i
      cached = self.class.token_cache[installation_id]
      return cached.value if cached && cached.expires_at > @clock.call + TOKEN_EXPIRY_BUFFER

      self.class.token_cache_mutex.synchronize do
        cached = self.class.token_cache[installation_id]
        return cached.value if cached && cached.expires_at > @clock.call + TOKEN_EXPIRY_BUFFER

        body = request(
          :post,
          "/app/installations/#{installation_id}/access_tokens",
          token: app_jwt,
        )
        unless body.is_a?(Hash) && body["token"].present?
          raise GitHubError, "GitHub returned an invalid installation token"
        end

        token = body["token"].to_s

        expires_at = parse_expiration(body["expires_at"])
        self.class.token_cache[installation_id] = Token.new(value: token, expires_at: expires_at)
        token
      end
    rescue KeyError, NoMethodError, TypeError, ArgumentError => e
      raise GitHubError, "GitHub returned an invalid installation token: #{e.message}"
    end

    private

    def installation_ids
      ids = Configuration.github_allowed_installation_ids.dup

      if ids.empty? && defined?(DiscourseGithubChat::GithubInstallation)
        ids.concat(
          DiscourseGithubChat::GithubInstallation
            .where(suspended_at: nil)
            .order(:github_installation_id)
            .pluck(:github_installation_id),
        )
      end
      ids = discover_installation_ids if ids.empty?
      ids = ids.compact.map(&:to_i).select(&:positive?).uniq
      if ids.empty?
        raise GitHubInstallationNotConfigured,
              "No GitHub App installation is known; install the App or configure the installation ID"
      end
      ids
    end

    def discover_installation_ids
      body = request(:get, "/app/installations?per_page=100", token: app_jwt)
      installations =
        if body.is_a?(Array)
          body
        elsif body.is_a?(Hash) && body["installations"].is_a?(Array)
          body["installations"]
        else
          []
        end
      ids = installations.filter_map do |installation|
        next unless installation.is_a?(Hash)

        id = Integer(installation["id"], exception: false)
        next unless id&.positive?
        next if parse_time(installation["suspended_at"])

        record_installation(id, installation)
        id
      end
      ids.uniq
    rescue GitHubInstallationNotConfigured, GitHubNotConfigured
      raise
    rescue GitHubError => e
      raise if e.retryable? || e.status == 401

      []
    end

    def record_installation(installation_id, installation)
      return unless defined?(DiscourseGithubChat::GithubInstallation)

      account = installation["account"].is_a?(Hash) ? installation["account"] : {}
      record = DiscourseGithubChat::GithubInstallation.find_or_initialize_by(
        github_installation_id: installation_id,
      )
      record.assign_attributes(
        account_login: account["login"].to_s.first(255),
        account_type: account["type"].to_s.first(64),
        suspended_at: parse_time(installation["suspended_at"]),
        last_event_at: Time.zone.now,
      )
      record.save!
    end

    def parse_time(value)
      return if value.blank?

      Time.zope.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def find_installation_repository(installation_id, repository_full_name, refreshed: false)
      target_full_name = repository_full_name.downcase
      token = installation_token(installation_id)
      page = 1

      while page <= MAX_REPOSITORY_PAGES
        body = request(
          :get,
          "/installation/repositories?per_page=100&page=#{page}",
          token: token,
        )
        repositories = body.is_a?(Hash) ? body["repositories"] : nil
        unless repositories.is_a?(Array)
          raise GitHubError, "GitHub returned an invalid repository list"
        end

        repositories.each do |item|
          next unless item.is_a?(Hash)

          id = Integer(item["id"], exception: false)
          full_name = item["full_name"].to_s
          next unless full_name.downcase == target_full_name

          html_url = item["html_url"].to_s
          if id.nil? || full_name.blank? || html_url.blank?
            raise GitHubError, "GitHub returned an invalid repository"
          end

          return Repository.new(
            id: id,
            full_name: full_name,
            html_url: html_url,
            private_repo: item["private"] == true,
          )
        end

        return nil if repositories.length < 100

        page += 1
      end

      nil
    rescue GitHubError => e
      if e.status == 401 && !refreshed
        self.class.clear_token_cache(installation_id)
        return find_installation_repository(
          installation_id,
          repository_full_name,
          refreshed: true,
        )
      end

      if e.retryable?
        raise
      end

      return nil if [403, 404, 422].include?(e.status)

      raise
    end

    def app_jwt
      if @app_id.blank? || @private_key.blank?
        raise GitHubNotConfigured, "GitHub App ID and private key must be configured"
      end

      now = @clock.call
      payload = {
        iat: now - 60,
        exp: now + 9 * 60,
        iss: @app_id.to_s,
      }
      signing_key = OpenSSL::PKey.read(@private_key)
      JWT.encode(payload, signing_key, "RS256", { typ: "JWT" })
    rescue JWT::EncodeError, OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError => e
      raise GitHubNotConfigured, "GitHub App private key is invalid: #{e.message}"
    end

    def request(method, path, token:, body: nil)
      uri = build_uri(path)
      headers = {
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => API_VERSION,
        "User-Agent" => "discourse-github-chat",
      }
      headers["Authorization"] = "Bearer #{token}" if token.present?
      headers["Content-Type"] = "application/json" if body

      response =
        if @http
          @http.call(method: method, uri: uri, headers: headers, body: body)
        else
          perform_request(method, uri, headers, body)
        end

      status = response_status(response)
      response_body = response_body(response)
      if response_body.to_s.bytesize > MAX_RESPONSE_BYTES
        raise GitHubError.new("GitHub API response is too large", status: status)
      end

      if status.to_i.between?(200, 299)
        return {} if response_body.to_s.empty?

        parsed = JSON.parse(response_body)
        return parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : {}
      end

      retryable = status.to_i == 429 || status.to_i >= 500 || retry_after?(response)
      message = "GitHub API request failed (status #{status})"
      raise GitHubError.new(message, status: status, retryable: retryable)
    rescue JSON::ParserError, ArgumentError => e
      raise GitHubError, "GitHub returned invalid JSON: #{e.message}"
    rescue IOError, SystemCallError, Timeout::Error, SocketError, Net::HTTPError, OpenSSL::SSL::SSLError => e
      raise GitHubTransportError, "GitHub API request failed: #{e.message}"
    end

    def perform_request(method, uri, headers, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 20

      request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      request = request_class.new(uri.request_uri)
      headers.each { |key, value| request[key] = value }
      request.body = JSON.generate(body) if body
      http.request(request)
    end

    def build_uri(path)
      base = @api_url.end_with?("/") ? @api_url : "#{@api_url}/"
      uri = URI.join(base, path.to_s.sub(%r{\A/}, ""))
      unless %w[http https].include?(uri.scheme) && uri.host.present?
        raise GitHubError, "GitHub API URL must be an HTTP(S) URL"
      end

      uri
    rescue URI::InvalidURIError => e
      raise GitHubError, "GitHub API URL is invalid: #{e.message}"
    end

    def response_status(response)
      return response.code.to_i if response.respond_to?(:code)

      value = response[:status] || response["status"]
      value.to_i
    end

    def response_body(response)
      return response.body.to_s if response.respond_to?(:body)

      (response[:body] || response["body"]).to_s
    end

    def response_headers(response)
      return response if response.respond_to?(:each_header)

      response[:headers] || response["headers"] || {}
    end

    def retry_after?(response)
      headers = response_headers(response)
      retry_after = headers["retry-after"] || headers[:retry_after]
      remaining = headers["x-ratelimit-remaining"] || headers[:x_ratelimit_remaining]
      retry_after.present? || remaining.to_s == "0"
    end

    def parse_expiration(value)
      Time.iso8601(value.to_s).to_i
    rescue ArgumentError
      @clock.call + 3600
    end
  end
end
