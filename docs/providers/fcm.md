# Firebase Cloud Messaging Connector (Erlang)

FCM HTTP v1 push over direct HTTP (OTP only — no vendor SDK, no runtime
dependencies). The RS256 service-account JWT is signed with OTP `public_key`.

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => fcm` to
`thinwrap_notifications:send_push/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => fcm,
    project_id => <<"my-project">>,
    client_email => <<"svc@my-project.iam.gserviceaccount.com">>,
    private_key => fun() -> env("FCM_PRIVATE_KEY") end
},
case thinwrap_notifications:send_push(Config, #{
    to => DeviceToken, title => <<"Hi">>, body => <<"Hello">>
}) of
    {ok, #{status := sent, provider_message_id := Name}} -> {sent, Name};
    {error, #{code := Code} = Err} -> {failed, Code, maps:get(status, Err, none)}
end.
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `project_id` | `binary()` | yes | Firebase / GCP project id (part of the send URL, path-escaped) |
| `client_email` | `binary()` | yes | Service-account `client_email` (the JWT `iss` claim) |
| `private_key` | `secret()` | yes | Service-account `private_key`: PEM RSA key (PKCS#8 `BEGIN PRIVATE KEY` or PKCS#1 `BEGIN RSA PRIVATE KEY`), signs the RS256 assertion |
| `token_cache` | `token_cache()` | no | Optional cache for the OAuth access token (see below) |

The three required keys map 1:1 to a Google service-account JSON file (decode
the file with `json:decode/1` and copy the three fields). Inject a custom
transport with the config's `transport` key (`transport => {MyTransport, Opts}`,
see `thinwrap_notifications_transport`); the default
`thinwrap_notifications_httpc` is HTTPS-only and never follows redirects.

### token_cache

By default the wrapper is **stateless**: it signs a fresh RS256
service-account JWT and exchanges it for an OAuth access token on **every**
send (two HTTP calls). To amortize that, supply a `token_cache` — a map of two
funs closing over whatever store you have (ETS, `persistent_term`, a
GenServer):

```erlang
Cache = #{
    get => fun(Key) ->
        case ets:lookup(tokens, Key) of
            [{_, Token, ExpiresAt}] -> {ok, {Token, ExpiresAt}};
            [] -> error
        end
    end,
    set => fun(Key, Token, ExpiresAt) -> ets:insert(tokens, {Key, Token, ExpiresAt}) end
},
Config1 = Config#{token_cache => Cache}.
```

The cache key is exactly `<<"fcm:", ProjectId/binary, ":", ClientEmail/binary>>`
(the credential identity is part of it, so a rotated service account never
serves a stale token). `ExpiresAt` is an absolute Unix time in seconds: Google's
reported `expires_in` minus a 60-second skew margin. An entry whose
`ExpiresAt` has passed is ignored and replaced. On a vendor 401 the wrapper
does **not** evict; eviction is the caller's responsibility.

## Auth setup

Download a service-account key from the Firebase console (Project settings →
Service accounts). The connector signs an RS256 JWT (scope
`https://www.googleapis.com/auth/firebase.messaging`, `aud` the token endpoint,
1-hour `exp`), exchanges it at `https://oauth2.googleapis.com/token` (form POST,
`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`), then sends
`Authorization: Bearer <token>`.

A key that fails to parse or sign (not RSA, malformed, truncated) returns
`{error, #{code := auth_failed}}` before any HTTP call, with only the failure
kind in `cause` (`#{<<"raw">> => #{<<"exception">> => <<"expected_rsa_key">>}}`
and similar) — never the key or the crypto exception. A non-2xx from the token
endpoint is `auth_failed` for 400/401 (`invalid_grant`, `invalid_client`),
`rate_limited` for 429 and `provider_unavailable` for 5xx; its message is
`FCM OAuth token exchange failed: <status> <body>`. A 200 without an
`access_token` is `auth_failed` (and is never cached).

## Endpoint

`POST https://fcm.googleapis.com/v1/projects/<project_id>/messages:send` — JSON
body `{"message": {...}}`.

## Narrowed input augmentations

`to` → `message.token` (omitted when `to` is empty); `title`/`body` →
`message.notification`; `data` → `message.data`. FCM's target is a oneof ("At
most one of the fields will be set": `token`, `fid`, `topic`, `condition`), so
when `passthrough.body` sets a non-empty `message.topic`, `message.condition` or
`message.fid`, the connector drops its own `token`. On success `status` is
`sent` and `provider_message_id` comes from the response `name`.

Sub-baseline FCM fields flow through `passthrough.body` under `message`
**verbatim** (FCM's wire body is not casing-transformed): `android`, `apns`,
`webpush`, `fcm_options`, topic-based delivery. `passthrough.headers` reach the
send request only (never the token exchange); `passthrough.query` is not
forwarded.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail. HTTP status maps first; the vendor
`error.status` string disambiguates a non-canonical HTTP status:

| Vendor signal | `code` |
|---|---|
| HTTP 401/403, or status UNAUTHENTICATED / SENDER_ID_MISMATCH | `auth_failed` |
| HTTP 404, or status NOT_FOUND | `invalid_recipient` |
| HTTP 429, or status QUOTA_EXCEEDED / RESOURCE_EXHAUSTED | `rate_limited` |
| HTTP ≥500, or status UNAVAILABLE / INTERNAL | `provider_unavailable` |
| HTTP 400, or status INVALID_ARGUMENT | `invalid_request` |
| (otherwise) | `unknown` |

The message is the vendor `error.message`, else `FCM HTTP <status>`. When the
vendor sends `Retry-After` (typically on 429), the error's `cause` carries the
raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_push(Config, #{
    to => DeviceToken,
    title => <<"Hi">>,
    body => <<"Hello">>,
    passthrough => #{body => #{<<"message">> => #{<<"android">> => #{<<"priority">> => <<"high">>}}}}
}),
%% Topic delivery: the topic replaces the device token.
{ok, _} = thinwrap_notifications:send_push(Config, #{
    title => <<"Breaking">>,
    passthrough => #{body => #{<<"message">> => #{<<"topic">> => <<"news">>}}}
}).
```

## Vendor docs

- API reference: https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages/send
- OAuth2 auth: https://firebase.google.com/docs/cloud-messaging/auth-server
- Error codes: https://firebase.google.com/docs/cloud-messaging/error-codes
