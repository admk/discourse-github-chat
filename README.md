# discourse-github-chat

A Discourse plugin that connects a GitHub App to Discourse Chat. It runs inside
Discourse, so GitHub can use the existing forum domain and no separate bridge
service, database, port, or public domain is required.

## Chat commands

Commands are slash-only. A bot mention is **not** required:

```text
/github subscribe owner/repository
/github unsubscribe owner/repository
/github help
```

Use `/github` on its own as a shorthand for `/github help`.

The value is a GitHub `owner/repository` name, such as `acme/widgets`. The
plugin resolves that name through the GitHub App installation and verifies that
the App can access the repository. The message must be the complete raw
message. For example, this is not a command:

```text
@github /github subscribe acme/widgets
```

The original command remains visible and the bot posts its response in the
same channel. `/github` is implemented as a server-side plugin command; it does
not add client-side slash-command autocomplete.

Any member who can send a message in a channel may manage that channel's
channel-wide subscription. This is intentional, but means that any member can
also unsubscribe other members. A per-member, per-channel rate limit is
applied.

## Features

- Issue notifications for `opened`, `closed`, and `reopened` actions.
- One Chat summary per repository push, with a configurable commit limit.
- Tag and `release-*`/`release/*` refs are labeled as releases and correctly
  count a populated `head_commit` even when GitHub sends an empty commit list.
- Public category channels by default.
- Restricted category channels and invited private channels when the bot is a
  member.
- Direct-message channels disabled by default.
- Private GitHub repositories disabled by default.
- GitHub App installation-token authentication and installation repository
  lookup.
- HMAC verification, delivery deduplication, semantic event deduplication,
  durable PostgreSQL records, Sidekiq retries, and stale-job recovery.

## Requirements

- A current Discourse installation with the Chat plugin enabled.
- A GitHub App installed on the repositories that should be available.
- A normal Discourse user for the bot (recommended), with Chat enabled.
- A public HTTPS forum URL that GitHub can reach.

The existing built-in `discourse-github` plugin is unrelated and is not
modified by this plugin. If the standalone bridge is still deployed, disable
its GitHub webhook and service before enabling this plugin so both
implementations do not process the same events.

## Installation

1. Copy this directory into the Discourse plugin directory as
   `discourse-github-chat`.
2. Make the plugin available to the image. For a Docker build, add a clone or
   mount step in the `after_code` hook in `samples/standalone.yml`, or bake the
   directory into the application image.
3. Run the plugin migration during deployment:

   ```bash
   bin/rails db:migrate
   ```

   When the plugin source is outside the Discourse tree, the included helper
   copies it and runs the migration for you:

   ```bash
   DISCOURSE_ROOT=/var/www/discourse ./bin/install
   ```

4. Enable **Chat** and **discourse-github-chat** in the Discourse admin area.
5. Configure the settings below.
6. Restart/rebuild the Discourse application and Sidekiq processes according to
   the normal plugin deployment procedure.

For a local checkout, the source directory is expected at:

```text
/var/www/discourse/plugins/discourse-github-chat
```

## GitHub App setup

Create a GitHub App with:

- **Webhook URL:** `https://forum.example.com/github-chat/webhooks/github`
- **Content type:** JSON
- **Webhook secret:** the value of
  `discourse_github_chat_github_webhook_secret`
- **Repository permissions:** Metadata (read), Issues (read), Contents (read)
- **Subscribe to events:** Issues and Push. Also select Installation and
  Installation repositories if the installation ID is not configured manually.

Install the App on the organizations or repositories that should be available.
Set the App ID and PEM private key in the plugin settings. The installation ID
is optional when installation webhooks are delivered, but setting it explicitly
is recommended for a single-installation deployment. For multiple installations,
set the installation allowlist.

The plugin uses the official
`/app/installations/{installation_id}/access_tokens` and
`/installation/repositories` endpoints to resolve an `owner/repository` name
during `/github subscribe`. The numeric repository ID is retained internally
for matching GitHub webhook events and deduplication.

If the App has not been installed, the bot replies with a direct installation
link. After installation, send the subscribe command again. If the installation
webhook was not delivered, the plugin can also discover the installation through
the App API on the first command; setting
`discourse_github_chat_github_installation_id` explicitly is recommended for
predictable behavior.

## Bot setup

Create a normal Discourse user, for example `github`, and enable Chat for that
user. Set `discourse_github_chat_bot_username` to that username. A dedicated
non-staff account is recommended.

For restricted category channels and private channels, invite the bot user to
the channel before subscribing or posting notifications. The plugin never
auto-joins a restricted channel. Public channels can be joined automatically
when `discourse_github_chat_allow_public_channel_join` is enabled.

If the configured username does not exist, runtime code falls back to the
Discourse system account. Creating the dedicated account is still recommended
because the system-account name is less clear and cannot replace a missing
private-channel membership.

## Settings

All settings are under the **Plugins** category.

| Setting | Purpose |
| --- | --- |
| `discourse_github_chat_enabled` | Enables the plugin. |
| `discourse_github_chat_github_app_id` | GitHub App ID. |
| `discourse_github_chat_github_private_key` | GitHub App PEM private key. |
| `discourse_github_chat_github_webhook_secret` | GitHub webhook HMAC secret. |
| `discourse_github_chat_github_installation_id` | Optional explicit installation ID. |
| `discourse_github_chat_github_allowed_installation_ids` | Optional installation allowlist. |
| `discourse_github_chat_github_api_url` | GitHub API base URL. |
| `discourse_github_chat_github_app_install_url` | Optional explicit GitHub App installation URL. |
| `discourse_github_chat_bot_username` | Username used for bot messages. |
| `discourse_github_chat_allowed_channel_ids` | Optional channel ID allowlist. |
| `discourse_github_chat_allow_private_repositories` | Allows private repository data. |
| `discourse_github_chat_allow_direct_message_channels` | Enables DM commands/notifications. |
| `discourse_github_chat_allow_public_channel_join` | Allows public-channel auto-join. |
| `discourse_github_chat_max_commits_in_summary` | Maximum commits in a push summary. |
| `discourse_github_chat_command_rate_limit_per_minute` | Per-member command limit. |
| `discourse_github_chat_max_delivery_attempts` | Chat delivery retry limit. |

The channel allowlist is empty by default, meaning all public category channels
are eligible. Direct messages remain disabled even when the allowlist is empty.

## Event and delivery behavior

The webhook controller verifies `X-Hub-Signature-256` against the raw request
body before parsing or queueing the payload. Payloads are minimized before they
are stored. GitHub delivery IDs are rejected if reused with a different body.
Issue and push events also receive a semantic deduplication key, so a replay
with a new delivery ID does not create a second notification for the same
channel and event.

A push is ignored for branch deletion. Issue actions other than `opened`,
`closed`, and `reopened` do not create notifications. Unsubscribing removes the
subscription and its pending notification records.

The plugin stores data in Discourse's PostgreSQL database and uses Sidekiq for
processing. Do not copy the old standalone service's SQLite database into this
plugin; migrate subscriptions by recreating them with `/github subscribe owner/repository`.

## Development and tests

The plugin follows Discourse plugin conventions. Run the normal Discourse test
suite with the plugin enabled, for example:

```bash
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-github-chat/spec
```

The specs cover slash parsing, Markdown-safe rendering, GitHub App token and
repository lookup behavior, webhook signatures/deduplication, subscription
uniqueness, and notification processing.
