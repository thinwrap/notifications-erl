# Apple Push Notification service Connector (Erlang)

APNs token-based (.p8) push over direct HTTP (OTP only — no vendor SDK, no
runtime dependencies). The ES256 provider JWT is signed with OTP `public_key`.

> **APNs requires HTTP/2, and the default transport cannot speak it.** The
> default `thinwrap_notifications_httpc` (OTP `httpc`) is HTTP/1.1-only, so a
> send through it returns `{error, #{code := invalid_request}}` before signing
> or touching the network, rather than attempting an HTTP/1.1 request APNs
> would refuse. Inject an HTTP/2-capable transport (for example one built on
> `gun`, Mint or Finch — see `thinwrap_notifications_transport`) with the
> config's `transport` key. The library itself ships no HTTP/2 client (zero
> runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => apns` to
`thinwrap_notifications:send_push/2`. Credentials may be a binary or a
zero-arity fun returning one:

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => apns,
    team_id => <<"ABCDE12345">>,
    key_id => <<"FGHIJ67890">>,
    private_key => fun() -> env("APNS_P8") end,
    bundle_id => <<"com.example.app">>,
    env => <<"production">>,
    token_cache => MyTokenCache,                 % required in production, see below
    transport => {my_http2_transport, #{}}       % required: APNs is HTTP/2-only
},
case thinwrap_notifications:send_push(Config, #{
    to => DeviceToken, title => <<"Hi">>, body => <<"Hello">>
}) of
    {ok, #{status := sent, provider_message_id := ApnsId}} -> {sent, ApnsId};
    {error, #{code := Code} = Err} -> {failed, Code, maps:get(status, Err, none)}
end.
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `team_id` | `binary()` | yes | 10-char Apple Developer Team ID (the JWT `iss` claim) |
| `key_id` | `binary()` | yes | 10-char APNs auth-key ID (the JWT `kid` header) |
| `private_key` | `secret()` | yes | The `.p8` contents: PKCS#8 PEM EC P-256 key (a SEC1 `BEGIN EC PRIVATE KEY` PEM also works), signs the ES256 JWT |
| `bundle_id` | `binary()` | yes | App bundle id → default `apns-topic` header (override per send via `passthrough.headers`) |
| `env` | `binary()` | no | `<<"production">>` → `api.push.apple.com`; `<<"sandbox">>` or absent/empty → `api.sandbox.push.apple.com`. Any other value returns `invalid_request` before sending, so a typo cannot send production tokens to the sandbox (where they fail as `BadDeviceToken`) |
| `token_cache` | `token_cache()` | no in the type, **yes in production** | Cache for the signed ES256 JWT; without it every send mints a new token and APNs answers `429 TooManyProviderTokenUpdates` (see below) |
| `transport` | `{module(), term()}` | no in the type, **yes in practice** | An HTTP/2-capable transport (see the note at the top) |

### token_cache

**`token_cache` is required in production.** The wrapper is stateless: without
a cache it signs a fresh ES256 JWT on **every** send, and Apple allows a new
provider token at most once every 20 minutes ("Refresh your token no more than
once every 20 minutes and no less than once every 60 minutes"). A second send
on a reused connection within that window gets
`429 TooManyProviderTokenUpdates`, and every retry trips it again, so it is
returned as `auth_failed` with a message naming `token_cache`. Without a cache,
only one-off or test sends are safe.

Supply a `token_cache` (`#{get := fun/1, set := fun/3}`, see the FCM page for
an ETS example) shared by every config that uses the same key — the cache key
is `<<"apns:", TeamId/binary, ":", KeyId/binary, ":", BundleId/binary>>`,
stored with a 50-minute TTL (`ExpiresAt` = now + 3000 s, Unix seconds), inside
Apple's 20–60 minute window. On a vendor 403 the wrapper does **not** evict;
eviction is the caller's responsibility.

## Auth setup

Create a `.p8` auth key in the Apple Developer portal. The connector signs an
ES256 JWT (`{"alg":"ES256","kid":KeyId,"typ":"JWT"}`, claims `iss` + `iat`;
the signature is the raw 64-byte `r||s` form JWS requires, not DER) and sends
`authorization: bearer <jwt>` plus the `apns-topic` header.

A key that fails to parse or sign (not EC P-256, malformed, truncated) returns
`{error, #{code := auth_failed}}` before any HTTP call, with only the failure
kind in `cause` (`#{<<"raw">> => #{<<"exception">> => <<"expected_p256_ec_key">>}}`
and similar) — never the key or the crypto exception.

## Endpoint

`POST https://<host>/3/device/<to>` — JSON body; `<host>` is
`api.push.apple.com` for `env => <<"production">>`, else
`api.sandbox.push.apple.com`. The device token is path-escaped.
`passthrough.query` is not forwarded (APNs reads none).

## Narrowed input augmentations

`title`/`body` → `aps.alert.{title,body}`; `data` keys merge at the **payload
root** alongside `aps` (a `data` key named `aps` is ignored — shape `aps` through
passthrough). Unless `passthrough.headers` sets it, `apns-push-type` is derived
from the **merged** payload: `alert` when `aps` carries an `alert`, `badge` or
`sound` (from `title`/`body` or from `passthrough.body`; Apple's alert type
covers "an alert, badge, or sound"; a badge of 0 counts, a `null` does not),
else `background`. For a background push the connector adds
`aps["content-available"] = 1` (unless present) and `apns-priority: 5` (unless
set) — Apple: "Always use priority 5. Using priority 10 is an error", and an
omitted priority means 10. APNs returns an **empty 200 body**, so `raw` is
`#{}`, `status` is `sent`, and `provider_message_id` is the `apns-id`
response header (`<<>>` when absent).

Sub-baseline body fields (`badge`, `sound`, the rest of the `aps` dictionary)
ride in `passthrough.body`; sub-baseline headers (`apns-priority`,
`apns-expiration`, `apns-collapse-id`, `apns-push-type`/`apns-topic`
overrides) ride in `passthrough.headers` (names match case-insensitively).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail. The error body carries `reason`:

| Vendor HTTP | Vendor `reason` | `code` |
|---|---|---|
| 400 or 403 | BadDeviceToken | `invalid_recipient` |
| 410 | (any) | `invalid_recipient` |
| 403 | (other, incl. Invalid/Missing/ExpiredProviderToken) | `auth_failed` |
| 400, 413 | (other) | `invalid_request` |
| 429 | TooManyProviderTokenUpdates (no `token_cache`: see above) | `auth_failed` |
| 429 | (other) | `rate_limited` |
| ≥500 | (any) | `provider_unavailable` |
| (otherwise) | | `unknown` |

The message is the `reason`, else `APNs HTTP <status>`. When the vendor sends
`Retry-After`, the error's `cause` carries the raw header under
`<<"retryAfter">>` and its parsed seconds under `<<"retryAfterSeconds">>`, next
to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_push(Config, #{
    to => DeviceToken,
    title => <<"Hi">>,
    body => <<"Hello">>,
    passthrough => #{
        body => #{<<"aps">> => #{<<"badge">> => 3, <<"sound">> => <<"default">>}},
        headers => #{<<"apns-collapse-id">> => <<"order-42">>}
    }
}).
```

## Vendor docs

- API reference: https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
- Authentication: https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
- Errors: https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns
