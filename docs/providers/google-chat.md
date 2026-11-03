# Google Chat Connector (Erlang)

Chat via Google Chat incoming webhooks over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => 'google-chat'` to
`thinwrap_notifications:send_chat/2`. The webhook URL embeds its token, so it
is a credential: it may be a binary or a zero-arity fun returning one (the fun
keeps the secret out of crash reports that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => 'google-chat',
    %% https://chat.googleapis.com/v1/spaces/AAA/messages?key=...&token=...
    webhook_url => fun() -> env("GOOGLE_CHAT_WEBHOOK_URL") end
},
{ok, #{status := sent, provider_message_id := Name}} =
    thinwrap_notifications:send_chat(Config, #{
        %% `to` is ignored — the webhook fixes the space
        body => <<"Build passed">>
    }).
```

Passing a provider that does not serve chat to `send_chat/2` raises
`error({badarg, Description})`.

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `webhook_url` | `secret()` | yes | Google Chat incoming-webhook URL (includes `?key=&token=`) — **the URL itself is the credential** |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

In a Google Chat space → space settings → Apps & integrations → Manage webhooks
→ Add. The URL embeds `?key=<key>&token=<token>` — both are part of the
credential surface and forwarded verbatim. This is webhook-URL-as-auth, so the
input's `to` is unused (each webhook is pinned to a space).

The URL must be `https://`: any other scheme returns `{error, #{code :=
invalid_request}}` before sending, whatever the transport, so the token never
travels in cleartext. Errors never echo the URL.

## Endpoint

`POST <webhook_url>` — the configured webhook URL is the endpoint. Its
`?key=&token=` credential query params are preserved; `passthrough.query` is
appended.

## Narrowed input augmentations

`to` is **ignored** (the webhook targets the space). `body` → wire `text` (sent
with `Content-Type: application/json; charset=UTF-8`). Unlike Slack/Teams,
Google Chat returns a full JSON Message resource on success, so `status` is
`sent` and `provider_message_id` carries the resource `name`
(`spaces/<space-id>/messages/<message-id>`).

Google Chat uses camelCase wire keys, so `passthrough.body` is **forwarded
verbatim (no casing transform)**. Expected keys: `cardsV2`, `thread`
(`{name}`), `fallbackText`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401, 403, 404 | (invalid key / revoked / deleted webhook / space) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 400 | (invalid card) | `invalid_request` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

The error's `provider_message` is extracted from the body's `error.message`.

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    body => <<"Build passed">>,
    passthrough => #{body => #{
        <<"cardsV2">> => [#{
            <<"cardId">> => <<"build-card">>,
            <<"card">> => #{
                <<"header">> => #{<<"title">> => <<"CI">>, <<"subtitle">> => <<"main">>}
            }
        }]
    }}
}).
```

## Vendor docs

- API reference: https://developers.google.com/workspace/chat/messages-overview
- Cards v2: https://developers.google.com/chat/api/guides/v1/messages/create#card
