# frozen_string_literal: true

require "digest"
require "json"
require "openssl"

module DiscourseGithubChat
  class WebhooksController < ::ApplicationController
    MAX_BODY_BYTES = 2 * 1024 * 1024
    DELIVERY_ID_FORMAT = /\A[a-zA-Z0-9._-]{1,255}\z/
    SIGNATURE_FORMAT = /\Asha256=[0-9a-f]{64}\z/i

    requires_plugin "discourse-github-chat"

    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required

    def github
      content_length = request.content_length.to_s.to_i
      return render json: { error: "Webhook body is too large" }, status: 413 if content_length > MAX_BODY_BYTES

      body = request.raw_post
      return render json: { error: "Webhook body is too large" }, status: 413 if body.to_s.bytesize > MAX_BODY_BYTES
      unless json_content_type?
        return render json: { error: "Expected application/json" }, status: :unsupported_media_type
      end
      return head :forbidden unless valid_signature?(body)

      event_type = single_header("X-GitHub-Event")&.downcase
      delivery_id = single_header("X-GitHub-Delivery")
      unless event_type.present? && delivery_id.to_s.match?(DELIVERY_ID_FORMAT)
        return render json: { error: "Missing or invalid GitHub delivery headers" }, status: :bad_request
      end

      payload = parse_payload(body)
      result =
        DiscourseGithubChat::WebhookIngest.call(
          delivery_id: delivery_id,
          event_type: event_type,
          payload: payload,
          payload_sha256: Digest::SHA256.hexdigest(body),
        )

      case result.error
      when :payload_conflict
        render json: { error: "Delivery ID was already used with a different payload" }, status: :conflict
      when :installation_not_allowed
        render json: { error: "GitHub installation is not allowed" }, status: :forbidden
      else
        render json: {
          accepted: true,
          queued: result.queued,
          duplicate: result.duplicate,
          event: result.event_type,
        }, status: result.queued ? :accepted : :ok
      end
    rescue JSON::ParserError, ActionDispatch::Http::Parameters::ParseError
      render json: { error: "Request body must be valid JSON" }, status: :bad_request
    end

    private

    def parse_payload(body)
      payload = JSON.parse(body.to_s)
      raise JSON::ParserError, "JSON object required" unless payload.is_a?(Hash)

      payload
    end

    def valid_signature?(body)
      secret = DiscourseGithubChat::Configuration.github_webhook_secret
      signature = single_header("X-Hub-Signature-256")
      return false if secret.blank? || signature.blank? || !signature.match?(SIGNATURE_FORMAT)

      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
      ActiveSupport::SecurityUtils.secure_compare(expected, signature.downcase)
    end

    def json_content_type?
      content_type = request.content_type.to_s.split(";", 2).first.to_s.strip.downcase
      content_type.blank? || content_type == "application/json"
    end

    def single_header(name)
      values =
        if request.headers.respond_to?(:get_all)
          request.headers.get_all(name)
        else
          [request.headers[name]]
        end
      values = Array(values).compact
      return if values.length != 1 || values.first.to_s.empty?

      values.first.to_s
    rescue StandardError
      request.headers[name].presence
    end
  end
end
