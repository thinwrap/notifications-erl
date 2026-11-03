# Mattermost Connector (Erlang)

Chat via Mattermost Incoming Webhooks over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => mattermost` to
`thinwrap_notifications:send_chat/2`. The webhook URL embeds its token, so it
is a credential: it may be a binary or a zero-arity fun returning one (the fun
keeps the secret out of crash reports that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => mattermost,
    %% https://mattermost.example.com/hooks/<id>
    webhook_url => fun() -> env("MATTERMOST_WEBHOOK_URL") end
},
{ok, #{status := sent, raw := <<"ok">>}} =
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
| `webhook_url` | `secret()` | yes | Mattermost Incoming Webhook URL — **the URL itself is the credential** and binds the default channel |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create an Incoming Webhook in Mattermost → Integrations → Incoming Webhooks. The
URL is the credential. (Each instance is self-hosted, so the host part of
`webhook_url` varies.)

The URL must be `https://`: any other scheme returns `{error, #{code :=
invalid_request}}` before sending, whatever the transport, so the token never
travels in cleartext. Errors never echo the URL.

## Endpoint

`POST <webhook_url>` — the configured webhook URL is the endpoint.

## Narrowed input augmentations

`to` is **optional**: when set it becomes the wire `channel` override
(server-config gated); the webhook otherwise posts to its bound default channel.
`body` → wire `text`. On success `status` is `sent`. Mattermost returns the
plain text `ok` (no JSON, no message id), so `provider_message_id` is **always
`<<>>`** and `raw` is the response text as a binary (`<<"ok">>`).

Keys in `passthrough.body` are sent **exactly as given**: write Mattermost's
snake_case wire names (`icon_url`, `icon_emoji`); the caller's free-form `props`
keys reach Mattermost unchanged. Mattermost adopted Slack's legacy attachment
format; `attachments` lists ride through `passthrough.body` verbatim — the
consumer supplies snake_case wire keys such as `author_name` / `image_url`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail (`cause`'s `<<"raw">>` is the response text).

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401, 403, 404 | (invalid / revoked / non-existent webhook) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 400 | (invalid payload) | `invalid_request` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the response text under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    %% channel override
    to => <<"town-square">>,
    body => <<"Build passed">>,
    passthrough => #{body => #{
        <<"attachments">> => [#{
            <<"color">> => <<"#36a64f">>,
            <<"text">> => <<"Build passed">>,
            <<"title">> => <<"CI">>
        }]
    }}
}).
```

## Vendor docs

- API reference: https://developers.mattermost.com/integrate/webhooks/incoming/
- Message attachments: https://developers.mattermost.com/integrate/reference/message-attachments/
