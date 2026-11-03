# Telegram Connector (Erlang)

Chat via the Telegram Bot API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => telegram` to
`thinwrap_notifications:send_chat/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => telegram,
    bot_token => fun() -> env("TELEGRAM_BOT_TOKEN") end
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_chat(Config, #{
        %% chat_id (numeric) or @channelname
        to => <<"@my_channel">>, body => <<"Hello from thinwrap">>
    }).
```

Passing a provider that does not serve chat to `send_chat/2` raises
`error({badarg, Description})`.

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `bot_token` | `secret()` | yes | Bot token from @BotFather; embedded in the request URL path |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create a bot via [@BotFather](https://t.me/BotFather) and copy its token. The
token is the credential — it is embedded in the request URL path
(`/bot<token>/sendMessage`), not a header. Static — no refresh.

## Endpoint

`POST https://api.telegram.org/bot<bot_token>/sendMessage` — single global endpoint.

## Narrowed input augmentations

`to` is **required** (`chat_id` numeric ID or `@channelname`) → wire `chat_id`;
`body` → wire `text`. A missing `to` returns `{error, #{code := invalid_request}}`
before any HTTP call. On success `status` is `sent` and `provider_message_id`
comes from `result.message_id` (a JSON number, formatted as a binary).

Telegram also emits a soft-rejection path: HTTP 200 with `ok: false`. This is
routed through the same error mapper using the body-supplied `error_code` (or
400 as a defensive fallback).

Rich Telegram fields ride in `passthrough.body`, with keys sent **exactly as
given**: write the Bot API's snake_case names (`parse_mode`,
`disable_notification`, `message_thread_id`, `reply_markup`, `entities`, and
nested ones such as `inline_keyboard` / `callback_data`).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 | bad token | `auth_failed` |
| 404 | malformed `/bot<token>/` path (the method is fixed, so this is the token) | `auth_failed` |
| 403 | blocked by the user, user deactivated, bot kicked / not a member | `invalid_recipient` |
| 400 | description contains `chat not found` / `user_id_invalid` / `peer_id_invalid` / `chat_id_invalid` | `invalid_recipient` |
| 400 | (other) | `invalid_request` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

Telegram sends no `Retry-After` header; on HTTP 429 the body's
`parameters.retry_after` (an integer) fills the same `cause` keys as a header
would: `<<"retryAfter">>` carries it as a binary (e.g. `<<"30">>`) and
`<<"retryAfterSeconds">>` as the integer, next to the decoded body under
`<<"raw">>`. There is no top-level retry key.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    to => <<"@my_channel">>,
    body => <<"*Hello* in MarkdownV2">>,
    passthrough => #{body => #{
        <<"parse_mode">> => <<"MarkdownV2">>,
        <<"disable_notification">> => true
    }}
}).
```

## Vendor docs

- API reference: https://core.telegram.org/bots/api#sendmessage
- Errors: https://core.telegram.org/api/errors
