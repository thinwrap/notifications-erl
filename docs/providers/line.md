# LINE Connector (Erlang)

Chat via the LINE Messaging API (Push) over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => line` to
`thinwrap_notifications:send_chat/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => line,
    channel_access_token => fun() -> env("LINE_CHANNEL_ACCESS_TOKEN") end
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_chat(Config, #{
        %% userId / groupId / roomId
        to => <<"U1234567890abcdef1234567890abcdef">>,
        body => <<"Hello from thinwrap">>
    }).
```

Passing a provider that does not serve chat to `send_chat/2` raises
`error({badarg, Description})`.

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `channel_access_token` | `secret()` | yes | Long-lived Channel Access Token from the LINE Developers Console (Bearer credential) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Generate a long-lived Channel Access Token in the LINE Developers Console →
your channel → Messaging API. Sent as `Authorization: Bearer
<channel_access_token>`. Static — no refresh.

## Endpoint

`POST https://api.line.me/v2/bot/message/push` — single global endpoint.

## Narrowed input augmentations

`to` is **required** (a `userId` / `groupId` / `roomId` from a LINE webhook
event) → wire `to`; a missing `to` returns `{error, #{code := invalid_request}}`
before any HTTP call. `body` is synthesized into a single text message
(`messages: [{type: "text", text: <body>}]`). On success `status` is `sent` and
`provider_message_id` comes from `sentMessages[0].id`.

LINE's wire keys are camelCase end-to-end, so `passthrough.body` is **forwarded
verbatim (no casing transform)**. A consumer wanting the full Message-object
surface (flex, sticker, image, template, quick-reply) supplies a `messages`
list via `passthrough.body` — it overrides the synthesized text message.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401, 403 | (any) | `auth_failed` |
| 400 | message contains `not found` / `userid` / `user id` | `invalid_recipient` |
| 400 | (other) | `invalid_request` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

The top-level `message` is surfaced as the error's `provider_message`;
per-property specifics (`details`) are readable from the decoded body under
`cause`'s `<<"raw">>`.

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    to => <<"U1234567890abcdef1234567890abcdef">>,
    body => <<"fallback for clients that can't render flex">>,
    passthrough => #{body => #{
        <<"messages">> => [#{
            <<"type">> => <<"flex">>,
            <<"altText">> => <<"Hello">>,
            <<"contents">> => #{<<"type">> => <<"bubble">>}
        }]
    }}
}).
```

## Vendor docs

- API reference: https://developers.line.biz/en/reference/messaging-api/#send-push-message
- Errors: https://developers.line.biz/en/reference/messaging-api/#error-responses
- Flex Messages: https://developers.line.biz/en/docs/messaging-api/using-flex-messages/
