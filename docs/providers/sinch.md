# Sinch Connector (Erlang)

Sinch SMS via direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => sinch` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => sinch,
    service_plan_id => env("SINCH_SERVICE_PLAN_ID"),
    api_token => fun() -> env("SINCH_API_TOKEN") end,
    from => <<"+15550000000">>,
    region => <<"eu">>
},
{ok, #{status := sent, provider_message_id := BatchId}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `service_plan_id` | `binary()` | yes | Sinch Service Plan ID (URL path segment, percent-escaped) |
| `api_token` | `secret()` | yes | Sinch Bearer token |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set, validated at send) |
| `region` | `binary()` | no | Regional cluster: `<<"us">>` (default), `<<"eu">>`, `<<"au">>`, `<<"br">>` or `<<"ca">>` — a subdomain prefix; any other value returns `{error, #{code := invalid_request}}` before sending |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get the Service Plan ID and API Token from the Sinch dashboard. The token is
sent as `Authorization: Bearer <api_token>`.

## Endpoint

`POST https://<region>.sms.api.sinch.com/xms/v1/<service_plan_id>/batches` —
JSON body. A `passthrough.query` is appended to the URL.

## Narrowed input augmentations

`from` (per-send or config, **required**) → `from`; `to` → `to` (the batches
API expects an array even for a single recipient, so the connector wraps
`[to]`); `body` → `body`. A missing sender returns
`{error, #{code := invalid_request}}` before any request. On success `status`
is `sent` and `provider_message_id` comes from the response `id`.

Keys ride in `passthrough.body` **exactly as given** (Sinch's snake_case wire
names): `delivery_report`, `send_at`, `expire_at`, `callback_url`,
`client_reference`, `feedback_enabled`, `flash_message`, `type`, `parameters`
(template variable names such as `firstName` reach Sinch unchanged).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| (other) | `code` invalid_destination / invalid_recipient | `invalid_recipient` |
| other ≥400 | (any) | `invalid_request` |
| (other) | — | `unknown` |

The vendor `code`/`text` are read from the JSON error body. When the vendor
sends `Retry-After` (typically on 429), the error's `cause` carries the raw
header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{
        body => #{
            delivery_report => <<"summary">>,
            callback_url => <<"https://example.com/dlr">>
        }
    }
}).
```

## Vendor docs

- API reference: https://developers.sinch.com/docs/sms/api-reference/sms/tag/Batches
- Regions: https://developers.sinch.com/docs/sms/api-reference
