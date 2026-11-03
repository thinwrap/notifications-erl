# Rocket.Chat Connector (Erlang)

Chat via Rocket.Chat Incoming Webhooks over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => 'rocket-chat'` to
`thinwrap_notifications:send_chat/2`. The webhook URL embeds its token, so it
is a credential: it may be a binary or a zero-arity fun returning one (the fun
keeps the secret out of crash reports that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => 'rocket-chat',
    %% https://rocket.example.com/hooks/<id>/<token>
    webhook_url => fun() -> env("ROCKET_CHAT_WEBHOOK_URL") end
},
{ok, #{status := sent}} =
    thinwrap_notifications:send_chat(Config, #{
        %% `to` is an optional channel override
        body => <<"Build passed">>
    }).
```

Passing a provider that does not serve chat to `send_chat/2` raises
`error({badarg, Description})`.

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `webhook_url` | `secret()` | yes | Rocket.Chat Incoming Webhook URL — **the URL itself is the credential**, so it must be `https://` (else `invalid_request` before sending, whatever the transport) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create an Incoming Webhook in Rocket.Chat → Administration → Integrations → New
→ Incoming. The URL is the credential. (Each instance is self-hosted, so the
host part of `webhook_url` varies.)

The URL must be `https://`: any other scheme returns `{error, #{code :=
invalid_request}}` before sending, whatever the transport, so the token never
travels in cleartext. Errors never echo the URL.

## Endpoint

`POST <webhook_url>` — the configured webhook URL is the endpoint.

## Narrowed input augmentations

`to` is **optional**: when set it overrides the webhook's default channel via
the wire `channel` field. `body` → wire `text`. On success `status` is `sent`.
Rocket.Chat Incoming Webhooks return `{success: true}` with no message id, so
`provider_message_id` is **always `<<>>`** (a non-JSON or empty success body
normalizes to `#{}` in `raw`).

`passthrough.body` is **forwarded verbatim (no casing transform)** in the
Rocket.Chat wire shape. Expected keys: `attachments`, `alias`, `avatar`,
`emoji`, `tmid`, `tshow`. Attachment keys are snake_case on the wire
(`author_name` / `image_url` / `thumb_url`).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401, 403, 404 | (invalid / disabled / deleted webhook) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 400 | (invalid payload) | `invalid_request` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

The error's `provider_message` is extracted from the body `error` field,
falling back to `message`.

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    %% channel override
    to => <<"#general">>,
    body => <<"Build passed">>,
    passthrough => #{body => #{
        <<"alias">> => <<"CI Bot">>,
        <<"attachments">> => [#{
            <<"color">> => <<"#36a64f">>,
            <<"text">> => <<"Build passed">>
        }]
    }}
}).
```

## Vendor docs

- API reference: https://docs.rocket.chat/use-rocket.chat/workspace-administration/integrations
