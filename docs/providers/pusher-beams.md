# Pusher Beams Connector (Erlang)

Pusher Beams push over direct HTTP (OTP only — no vendor SDK, no runtime
dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => 'pusher-beams'` (a
quoted atom) to `thinwrap_notifications:send_push/2`:

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => 'pusher-beams',
    instance_id => env("BEAMS_INSTANCE_ID"),
    secret_key => fun() -> env("BEAMS_SECRET_KEY") end
},
case thinwrap_notifications:send_push(Config, #{
    to => UserId, title => <<"Hi">>, body => <<"Hello">>
}) of
    {ok, #{status := sent, provider_message_id := PublishId}} -> {sent, PublishId};
    {error, #{code := Code} = Err} -> {failed, Code, maps:get(status, Err, none)}
end.
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `instance_id` | `binary()` | yes | Beams instance ID (part of both the host and the path), so it must be a single DNS label (letters, digits, `-`) or the send returns `invalid_request` before any HTTP call |
| `secret_key` | `secret()` | yes | Server-side secret key; sent verbatim as `Authorization: Bearer <secret_key>` — no signing, no caching |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get the Instance ID and Secret Key from the Beams dashboard. The secret key is
sent verbatim as `Authorization: Bearer <secret_key>`.

## Endpoint

`POST https://<instance_id>.pushnotifications.pusher.com/publish_api/v1/instances/<instance_id>/publishes/<suffix>`
— JSON body. `<suffix>` is `interests` when a (non-`null`) `interests`
passthrough body key is present, else `users`. `passthrough.query` is not
forwarded.

## Narrowed input augmentations

Beams is the canonical outlier: the publisher must send parallel `fcm` /
`apns` / `web` platform payloads in one request, which the connector
synthesizes from the baseline. `title`/`body` → each platform's
notification/alert (omitted when both are empty); `data` → `fcm.data`,
`web.data` and `apns.data` (Beams documents custom iOS data under `apns.data`;
values are already strings, matching FCM's string-only constraint). A
data-only send is a silent push: iOS gets
`apns.aps = #{<<"content-available">> => 1}` instead of an empty alert. By
default `to` → `users: [to]`. On success `status` is `sent` and
`provider_message_id` comes from the response `publishId`.

Sub-baseline fields flow through `passthrough.body` **verbatim** (deep-merged
onto the synthesized platform blocks): `badge`, `sound`, `ttl`, platform-block
overrides. Recipient routing precedence is `interests` > `users` > `[to]`:
supplying an `interests` or `users` key overrides the default `users: [to]`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail. Per the
[Publish API](https://pusher.com/docs/beams/reference/publish-api/) error
table:

| Vendor HTTP | Beams description | `code` |
|---|---|---|
| 400 | invalid content type, incomplete request, body too large, body not JSON | `invalid_request` |
| 401 | "Incorrect API Key." | `auth_failed` |
| 402 | "Publishing has been blocked due to being over plan limits." | `rate_limited` |
| 403 | (not in Beams' table; treated as a credential error) | `auth_failed` |
| 404 | "Could not find the instance." (wrong `instance_id`) | `invalid_request` |
| 422 | "JSON does not our match schema." | `invalid_request` |
| 429 | "Too many requests being made in quick succession (max 100 RPS)." | `rate_limited` |
| ≥500 | "Internal server error." | `provider_unavailable` |
| (otherwise) | | `unknown` |

The message is the body's `error` field, else `Pusher Beams <status>`. When the
vendor sends `Retry-After` (typically on 429), the error's `cause` carries the
raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_push(Config, #{
    title => <<"Hi">>,
    body => <<"Hello">>,
    passthrough => #{body => #{<<"interests">> => [<<"debates">>]}}
}).
```

## Vendor docs

- API reference: https://pusher.com/docs/beams/reference/publish-api/
- Errors: https://pusher.com/docs/beams/reference/publish-api/#error-responses
