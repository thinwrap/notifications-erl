# Textmagic Connector (Erlang)

Textmagic SMS via direct HTTP (OTP only — no vendor SDK, no runtime
dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => textmagic` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => textmagic,
    username => env("TEXTMAGIC_USERNAME"),
    api_key => fun() -> env("TEXTMAGIC_API_KEY") end,
    from => <<"Acme">>
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `username` | `binary()` | yes | Account username (sent as the `X-TM-Username` header) |
| `api_key` | `secret()` | yes | API key (sent as the `X-TM-Key` header) |
| `from` | `binary()` | no | Default sender (alphanumeric or E.164); a per-send `from` overrides it |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get the username and API key from the Textmagic account settings. Unlike every
other wrapped SMS provider, auth is a **two-header pair**: `X-TM-Username` and
`X-TM-Key` (neither Basic nor Bearer).

## Endpoint

`POST https://rest.textmagic.com/api/v2/messages` — single global endpoint,
`application/x-www-form-urlencoded`.

## Narrowed input augmentations

`body` → `text`; `to` → `phones` (Textmagic's field name; it supports a
comma-separated multi-recipient list there); `from` (per-send or config,
optional) → `from`. On success `status` is `sent`; `provider_message_id` is the
response `id` (or `messageId` when returned), stringified — an accepted send
never crashes on an odd id value.

Textmagic's wire keys are camelCase, and `passthrough.body` merges
**verbatim** and flattens into the form. Sub-baseline fields: `templateId`,
`sendingTime`, `tz`, `partsCount`, `referenceId`, `rrule`, `cutExtra` (encode
booleans as `<<"1">>`/`<<"0">>`).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | `code` |
|---|---|
| 401 / 403 | `auth_failed` |
| 429 | `rate_limited` |
| 422 | `invalid_recipient` |
| 5xx | `provider_unavailable` |
| other ≥400 | `invalid_request` |
| (other) | `unknown` |

The error `message`/`code` are read from the JSON body. When the vendor sends
`Retry-After` (typically on 429), the error's `cause` carries the raw header
under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{body => #{referenceId => <<"order-42">>, cutExtra => <<"1">>}}
}).
```

## Vendor docs

- API reference: https://docs.textmagic.com/#tag/Outbound-Messages/operation/sendMessage
- Auth: https://docs.textmagic.com/#section/Authentication
