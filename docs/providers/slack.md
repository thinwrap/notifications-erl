# Slack Connector (Erlang)

Chat via Slack Incoming Webhooks over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => slack` to
`thinwrap_notifications:send_chat/2`. The webhook URL embeds its token, so it
is a credential: it may be a binary or a zero-arity fun returning one (the fun
keeps the secret out of crash reports that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => slack,
    %% https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXX
    webhook_url => fun() -> env("SLACK_WEBHOOK_URL") end
},
{ok, #{status := sent, raw := <<"ok">>}} =
    thinwrap_notifications:send_chat(Config, #{
        %% `to` is ignored — the webhook fixes the channel
        body => <<"Hello from thinwrap">>
    }).
```

Passing a provider that does not serve chat to `send_chat/2` raises
`error({badarg, Description})`.

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `webhook_url` | `secret()` | yes | Slack Incoming Webhook URL — **the URL itself is the credential** and fixes the channel |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create an Incoming Webhook at https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks. The URL
itself is the credential — anyone with it can post to the destination channel.
Treat it as a secret. This is webhook-URL-as-auth, so the input's `to` is
unused (the channel was pinned when the webhook was created).

The URL must be `https://`: any other scheme returns `{error, #{code :=
invalid_request}}` before sending, whatever the transport, so the token never
travels in cleartext. Errors never echo the URL.

## Endpoint

`POST <webhook_url>` — the configured webhook URL is the endpoint.

## Narrowed input augmentations

`to` is **ignored** (the webhook targets the channel). `body` → wire `text`. On
success `status` is `sent`. Slack returns the plain text `ok` (not JSON) on
success, so `provider_message_id` is **always `<<>>`** and `raw` is the response
text as a binary (`<<"ok">>`).

Rich content (Block Kit `blocks`, `attachments`, threading) rides in
`passthrough.body`, with keys sent **exactly as given**: write Slack's
snake_case wire names (`icon_emoji`, `thread_ts`, `unfurl_links`, `link_names`,
and nested ones such as `metadata.event_payload`).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail (`cause`'s `<<"raw">>` is the response text).

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401, 403, 404 | (revoked / deleted webhook) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 400 | (e.g. `no_text` / `invalid_payload`) | `invalid_request` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the response text under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    body => <<"fallback for clients that don't render blocks">>,
    passthrough => #{body => #{
        <<"blocks">> => [#{
            <<"type">> => <<"section">>,
            <<"text">> => #{<<"type">> => <<"mrkdwn">>, <<"text">> => <<"*Hello* world">>}
        }]
    }}
}).
```

## Vendor docs

- API reference: https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks
- Block Kit: https://docs.slack.dev/block-kit/
- Errors: https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks
