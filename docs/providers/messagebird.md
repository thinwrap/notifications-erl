# MessageBird Connector (Erlang)

MessageBird (now branded "Bird") SMS via direct HTTP (OTP only — no vendor
SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => messagebird` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => messagebird,
    access_key => fun() -> env("MESSAGEBIRD_ACCESS_KEY") end,
    from => <<"Acme">>
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `access_key` | `secret()` | yes | Sent via the custom `Authorization: AccessKey <accessKey>` scheme |
| `from` | `binary()` | no | Default originator; a per-send `from` overrides it (one must be set, validated at send) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get a live access key from the MessageBird/Bird dashboard. It is sent via the
custom `Authorization: AccessKey <accessKey>` scheme (not Bearer, not Basic).
The connector targets the legacy `rest.messagebird.com` v1.0 surface.

## Endpoint

`POST https://rest.messagebird.com/messages` — JSON body.

## Narrowed input augmentations

`from` (per-send or config, **required**) → `originator`; `to` → `recipients`
(wrapped as `[to]` — MessageBird requires a recipients array); `body` → `body`.
A missing originator returns `{error, #{code := invalid_request}}` before any
request. On success `status` is `sent` and `provider_message_id` comes from the
response `id`.

MessageBird's wire keys are mostly camelCase (a few are lowercased-flat), and
`passthrough.body` merges **verbatim** (no casing transform). Sub-baseline
fields ride using their exact wire keys: `type`, `reference`, `validity`,
`gateway`, `typeDetails`, `datacoding`, `mclass`, `scheduledDatetime`.

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

The error body shape is `{errors:[{code,description,parameter}]}`; the message
is `errors[0].description` and the numeric `code` is kept in `cause` but not
mapped — the HTTP status drives classification. When the vendor sends
`Retry-After` (typically on 429), the error's `cause` carries the raw header
under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{body => #{reference => <<"order-42">>, datacoding => <<"unicode">>}}
}).
```

## Vendor docs

- API reference: https://developers.messagebird.com/api/sms-messaging/
- Errors: https://developers.messagebird.com/api/#errors
