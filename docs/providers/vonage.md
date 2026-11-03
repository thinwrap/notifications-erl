# Vonage Connector (Erlang)

Vonage (Nexmo) SMS via direct HTTP (OTP only — no vendor SDK, no runtime
dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => vonage` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => vonage,
    api_key => fun() -> env("VONAGE_API_KEY") end,
    api_secret => fun() -> env("VONAGE_API_SECRET") end,
    from => <<"Acme">>
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `secret()` | yes | Vonage `api_key` — sent as a **form field**, not a header |
| `api_secret` | `secret()` | yes | Vonage `api_secret` — sent as a **form field**, not a header |
| `from` | `binary()` | no | Default sender (E.164 or alphanumeric); a per-send `from` overrides it (one must be set) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get `api_key` / `api_secret` from the Vonage dashboard. Unlike most SMS
providers, Vonage authenticates via `api_key` and `api_secret` **form fields**
in the request body, not an HTTP header.

## Endpoint

`POST https://rest.nexmo.com/sms/json` — `application/x-www-form-urlencoded`.

## Narrowed input augmentations

`from` (per-send or config, **required**) → `from`; `to` → `to`; `body` →
`text`. A missing sender returns `{error, #{code := invalid_request}}` before
any request. On success `status` is `sent` and `provider_message_id` comes from
`messages[0].message-id`.

Vonage returns **HTTP 200 even for soft errors** — `messages[0].status` is the
source of truth. Status `"0"` is success; any other status maps via the
soft-error table below, falling back to `unknown`. A 200 without
`messages[0]` is `unknown`.

Keys ride in `passthrough.body` **exactly as given** (Vonage's kebab-case wire
names): `client-ref`, `message-class`, `status-report-req`, `ttl`, `callback`,
`type`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

HTTP layer (a non-2xx body is not the messages envelope, so `cause`'s
`<<"raw">>` is the response text):

| Vendor HTTP | `code` |
|---|---|
| 401 / 403 | `auth_failed` |
| 429 | `rate_limited` |
| 5xx | `provider_unavailable` |
| other ≥400 | `invalid_request` |
| (other) | `unknown` |

Soft errors in `messages[0].status` (HTTP 200):

| Status codes | `code` |
|---|---|
| 1 | `rate_limited` |
| 4, 8, 9 | `auth_failed` |
| 5 | `provider_unavailable` |
| 7, 29, 34 | `invalid_recipient` |
| 2, 3, 6, 11, 12, 13, 14, 15, 16, 19, 20, 23 | `invalid_request` |
| (unmapped) | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{body => #{<<"client-ref">> => <<"order-42">>, <<"type">> => <<"unicode">>}}
}).
```

## Vendor docs

- API reference: https://developer.vonage.com/en/api/sms
- Error codes: https://developer.vonage.com/en/api/sms#errors
