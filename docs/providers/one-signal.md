# OneSignal Connector (Erlang)

OneSignal push (Create notification) over direct HTTP (OTP only — no vendor
SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => 'one-signal'` (a
quoted atom) to `thinwrap_notifications:send_push/2`:

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => 'one-signal',
    app_id => env("ONESIGNAL_APP_ID"),
    api_key => fun() -> env("ONESIGNAL_APP_API_KEY") end   % "os_v2_..."
},
case thinwrap_notifications:send_push(Config, #{
    to => SubscriptionId, title => <<"Hi">>, body => <<"Hello">>
}) of
    {ok, #{status := sent, provider_message_id := Id}} -> {sent, Id};
    {error, #{code := Code} = Err} -> {failed, Code, maps:get(status, Err, none)}
end.
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `app_id` | `binary()` | yes | UUID app id from the OneSignal dashboard (sent as `app_id`) |
| `api_key` | `secret()` | yes | App API key (**not** the user-auth / Organization key). An `os_v2_…` key is sent as `Authorization: Key <api_key>`; any other (legacy) key as `Authorization: Basic <api_key>` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get the App ID and an App API key from the OneSignal dashboard (Settings → Keys
& IDs). Both key generations are accepted, and the key selects the endpoint and
auth scheme:

- **Current App API keys** (prefixed `os_v2_`) → `Authorization: Key <api_key>`
  against `api.onesignal.com`.
- **Legacy REST API keys** (no longer creatable, still honored) →
  `Authorization: Basic <api_key>` against `onesignal.com/api/v1`.

## Endpoint

- `os_v2_` key: `POST https://api.onesignal.com/notifications?c=push`
- legacy key: `POST https://onesignal.com/api/v1/notifications`

Single global endpoint per key generation, JSON body. `passthrough.query` is
not forwarded.

## Narrowed input augmentations

By default `to` → `include_subscription_ids: [to]`; `title` → `headings.en`;
`body` → `contents.en`; `data` → `data`. On success `status` is `sent` and
`provider_message_id` comes from the response `id`.

OneSignal returns **HTTP 200 even when all recipients are invalid**; the
`errors` field is inspected after the HTTP layer and known invalid-recipient
markers (case-insensitive: "all included players are not subscribed",
`invalid_player_ids`, `invalid_external_user_ids`, "no subscriptions"; or an
errors object with a non-empty `invalid_player_ids`, `invalid_external_user_ids`
or `invalid_aliases`) map to `invalid_recipient`. A 200 with no `id` and no
known marker is `invalid_request`. A 200 that carries a notification `id` is a
success even when `errors` lists some invalid targets: the notification was
created, and the skipped targets stay in `raw`'s `<<"errors">>`.

The wire body is snake_case-native, so `passthrough.body` merges **verbatim**:
`ttl`, `priority`, localized `headings`/`contents`, platform blocks,
scheduling. Supplying any (non-`null`) targeting key (`include_aliases` (with
`target_channel`), `include_subscription_ids`, `included_segments`,
`excluded_segments`, `filters`, `include_player_ids`,
`include_external_user_ids`, `include_email_tokens`, `include_phone_numbers`)
**suppresses** the default `include_subscription_ids`, since OneSignal rejects
mixing aliases or segments with other targeting.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | `code` |
|---|---|
| 401 | `auth_failed` |
| 400 | `invalid_request` |
| 404 | `invalid_request` |
| 429 | `rate_limited` |
| 500, 503 (and other ≥500) | `provider_unavailable` |
| (otherwise) | `unknown` |

The message is the first `errors` string, else the `errors` object as JSON,
else `message`, else `OneSignal <status>`. When the vendor sends
`Retry-After` (typically on 429), the error's `cause` carries the raw header
under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_push(Config, #{
    title => <<"Hi">>,
    body => <<"Hello">>,
    passthrough => #{body => #{<<"included_segments">> => [<<"Subscribed Users">>]}}
}).
```

## Vendor docs

- API reference: https://documentation.onesignal.com/reference/push-notification
- Keys & IDs: https://documentation.onesignal.com/docs/en/keys-and-ids
- Errors: https://documentation.onesignal.com/reference/rate-limits
