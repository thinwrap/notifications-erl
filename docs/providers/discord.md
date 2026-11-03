# Discord Connector (Erlang)

Chat via Discord Incoming Webhooks over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => discord` to
`thinwrap_notifications:send_chat/2`. The webhook URL embeds its token, so it
is a credential: it may be a binary or a zero-arity fun returning one (the fun
keeps the secret out of crash reports that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => discord,
    %% https://discord.com/api/webhooks/<id>/<token>
    webhook_url => fun() -> env("DISCORD_WEBHOOK_URL") end
},
{ok, #{status := sent, provider_message_id := Id}} =
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
| `webhook_url` | `secret()` | yes | Discord channel webhook URL — **the URL itself is the credential** |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create a webhook in Discord → Channel Settings → Integrations → Webhooks. The
URL is the credential. This is webhook-URL-as-auth, so the input's `to` is
unused (each webhook is pinned to a channel).

The URL must be `https://`: any other scheme returns `{error, #{code :=
invalid_request}}` before sending, whatever the transport, so the token never
travels in cleartext. Errors never echo the URL.

## Endpoint

`POST <webhook_url>` — the configured webhook URL is the endpoint. `?wait=true`
is always appended (overridable via `passthrough.query`) so Discord returns the
created message JSON instead of an empty 204.

## Narrowed input augmentations

`to` is **ignored** (the webhook targets the channel). `body` → wire `content`.
On success `status` is `sent`; with `?wait=true`, `provider_message_id` comes
from the created message's `id` (`<<>>` when Discord returns 204 / an empty
body, with `raw` then `null`).

Rich content (`embeds`, `components`, `username`/avatar overrides) rides in
`passthrough.body`, with keys sent **exactly as given**: write Discord's
snake_case wire names (`avatar_url`, `allowed_mentions`, `thread_name`, and
nested ones such as `allowed_mentions.replied_user`). Target an existing thread
by adding `thread_id` to `passthrough.query`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401, 403, 404 | (revoked / deleted webhook) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 400 | (invalid `content` / embed) | `invalid_request` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.
Discord's body-supplied `retry_after` (seconds, float) is preserved in that
`<<"raw">>` body.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    body => <<"Headline">>,
    passthrough => #{
        body => #{
            <<"embeds">> => [#{
                <<"title">> => <<"Build passed">>,
                <<"description">> => <<"Tag v1.0.0">>,
                <<"color">> => 16#57F287
            }],
            <<"username">> => <<"CI Bot">>
        },
        %% post into an existing thread
        query => #{<<"thread_id">> => <<"1234567890123456789">>}
    }
}).
```

## Vendor docs

- API reference: https://discord.com/developers/docs/resources/webhook#execute-webhook
- Rate limits: https://discord.com/developers/docs/topics/rate-limits
