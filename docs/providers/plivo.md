# Plivo Connector (Erlang)

Plivo SMS via direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => plivo` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => plivo,
    auth_id => env("PLIVO_AUTH_ID"),
    auth_token => fun() -> env("PLIVO_AUTH_TOKEN") end,
    from => <<"+15550000000">>
},
{ok, #{status := sent, provider_message_id := Uuid}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `auth_id` | `binary()` | yes | Account Auth ID — used both in the URL path (percent-escaped) and as the Basic-auth username |
| `auth_token` | `secret()` | yes | Auth Token (Basic-auth password) |
| `from` | `binary()` | no | Default sender (E.164 or short code); a per-send `from` overrides it. Omit only when a `powerpack_uuid` passthrough is supplied |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get the Auth ID and Auth Token from the Plivo console. They are sent as HTTP
Basic auth (`Authorization: Basic base64(authId:authToken)`).

## Endpoint

`POST https://api.plivo.com/v1/Account/<auth_id>/Message/` — JSON body. The
trailing slash is required.

## Narrowed input augmentations

`to` → `dst`; `body` → `text`; `from` (per-send or config) → `src`. Either a
`from` or a non-null `powerpack_uuid` passthrough is required (else
`{error, #{code := invalid_request}}`, no request sent). On success `status`
is `sent`; `message_uuid` is an array and `provider_message_id` reports
`message_uuid[0]` (the full list stays in `raw`).

Keys ride in `passthrough.body` **exactly as given** (Plivo's snake_case wire
names): `powerpack_uuid`, `dlt_entity_id`, `dlt_template_id`,
`dlt_template_category`, `template_id`, `url`, `method`, `log`, `trackable`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | `code` |
|---|---|
| 401 / 403 | `auth_failed` |
| 429 | `rate_limited` |
| 5xx | `provider_unavailable` |
| other ≥400 | `invalid_request` |
| (other) | `unknown` |

The error message is read from the JSON `error` field. When the vendor sends
`Retry-After` (typically on 429), the error's `cause` carries the raw header
under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{
        body => #{trackable => true, dlt_template_id => <<"1207161234567890">>}
    }
}).
```

## Vendor docs

- API reference: https://www.plivo.com/docs/messaging/api/message/send-a-message
- Errors: https://www.plivo.com/docs/messaging/troubleshooting/error-codes
