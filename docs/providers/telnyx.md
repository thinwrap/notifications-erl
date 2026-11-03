# Telnyx Connector (Erlang)

Telnyx SMS via direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => telnyx` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => telnyx,
    api_key => fun() -> env("TELNYX_API_KEY") end,
    from => <<"+15550000000">>
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `secret()` | yes | Telnyx API key (Bearer secret) |
| `from` | `binary()` | no | Default sender (E.164, short code, or alphanumeric); a per-send `from` overrides it. Omit only when a `messaging_profile_id` passthrough is supplied |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create an API key in the Telnyx portal. It is sent as
`Authorization: Bearer <api_key>`.

## Endpoint

`POST https://api.telnyx.com/v2/messages` — single global endpoint, JSON body.

## Narrowed input augmentations

`to` → `to`; `body` → `text`; `from` (per-send or config) → `from`. Either a
`from` or a non-null `messaging_profile_id` passthrough is required (else
`{error, #{code := invalid_request}}`, no request sent). Telnyx wraps success
in a JSON:API `{"data": {...}}` envelope; on success `status` is `sent` and
`provider_message_id` unwraps `data.id` (the full envelope stays on `raw`).

Keys ride in `passthrough.body` **exactly as given** (Telnyx's snake_case wire
names): `messaging_profile_id`, `webhook_url`, `webhook_failover_url`,
`use_profile_webhooks`, `auto_detect`, `media_urls`, `type`, `subject`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail. The numeric-string `errors[0].code` decides
first; the HTTP status is the fallback. Only synchronous codes appear here:
Telnyx's 400xx delivery errors arrive only in the `message.finalized` webhook,
never in the send response.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| (any) | code `40300` (STOP), `40309`, `40310` (invalid `to`); `10002` (invalid phone number) with `source.pointer == "/to"` | `invalid_recipient` |
| (any) | code `10009`, `10010`, `20001`, `20006`, `40311`, `40313` | `auth_failed` |
| (any) | code `10011`, `40318` (queue full) | `rate_limited` |
| (any) | code `40305` (invalid `from`), other `403xx` request errors, `10002` (other fields), `10004`, `10015`, `20100` | `invalid_request` |
| 401 / 403 | (other) | `auth_failed` |
| 429 | (other) | `rate_limited` |
| 5xx | (other) | `provider_unavailable` |
| other ≥400 (incl. a bare 422) | (other) | `invalid_request` |
| (other) | — | `unknown` |

The message is `errors[0].detail`, else `errors[0].title`. When the vendor
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
            messaging_profile_id => <<"40000000-0000-0000-0000-000000000000">>,
            webhook_url => <<"https://example.com/hook">>
        }
    }
}).
```

## Vendor docs

- API reference: https://developers.telnyx.com/docs/messaging/messages/send-message
- Errors: https://developers.telnyx.com/docs/messaging/messages/error-codes/index
