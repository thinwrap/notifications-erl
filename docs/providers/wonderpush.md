# WonderPush Connector (Erlang)

WonderPush Management API push over direct HTTP (OTP only — no vendor SDK, no
runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => wonderpush` to
`thinwrap_notifications:send_push/2`:

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => wonderpush,
    access_token => fun() -> env("WONDERPUSH_ACCESS_TOKEN") end,
    application_id => env("WONDERPUSH_APP_ID")   % optional
},
case thinwrap_notifications:send_push(Config, #{
    to => UserId, title => <<"Hi">>, body => <<"Hello">>
}) of
    {ok, #{status := sent, provider_message_id := Id}} -> {sent, Id};
    {error, #{code := Code} = Err} -> {failed, Code, maps:get(status, Err, none)}
end.
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `access_token` | `secret()` | yes | Management API access token; sent as `Authorization: Bearer <access_token>` |
| `application_id` | `binary()` | no | Optional WonderPush application id; when set (non-empty) it is forwarded into the body as `applicationId` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get a Management API access token from the WonderPush dashboard. It is sent as
`Authorization: Bearer <access_token>`.

## Endpoint

`POST https://management-api.wonderpush.com/v1/deliveries` — single global
endpoint, JSON body. Unlike the other push connectors, `passthrough.query` is
forwarded.

## Narrowed input augmentations

`to` → `targetUserIds: [to]`; `title` → `notification.alert.title`; `body` →
`notification.alert.text`; `data` → `notification.push.custom` (empty parts
omitted). When set, the config's `application_id` → `applicationId`. On
success `status` is `sent` and `provider_message_id` comes from the response
`id` (falling back to `notificationId`).

The wire body is camelCase-native, so `passthrough.body` merges **verbatim**
(deep-merged, so a partial `notification` block keeps the synthesized
alert/custom data): platform alert fields such as
`notification.alert.ios.subtitle`, `notification.alert.ios.sound`,
`notification.alert.ios.badge`, `notification.alert.android.sound`,
`targetSegmentIds`, `customSegmentation`, and a `targetUserIds` override (a
supplied list replaces the default).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | `code` |
|---|---|
| 401 | `auth_failed` |
| 404 | `invalid_recipient` |
| 429 | `rate_limited` |
| 400 (and other 4xx) | `invalid_request` |
| ≥500 | `provider_unavailable` |
| (otherwise) | `unknown` |

The message is the body's `error.message`, else `WonderPush HTTP <status>`.
When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_push(Config, #{
    title => <<"Hi">>,
    body => <<"Hello">>,
    passthrough => #{body => #{
        <<"targetSegmentIds">> => [<<"@ALL">>],
        <<"notification">> => #{<<"alert">> => #{
            <<"ios">> => #{<<"sound">> => <<"default">>, <<"badge">> => 1, <<"subtitle">> => <<"Today">>},
            <<"android">> => #{<<"sound">> => <<"default">>}
        }}
    }}
}).
```

## Vendor docs

- API reference: https://docs.wonderpush.com/reference/post-deliveries
- Auth: https://docs.wonderpush.com/reference/authentication
- Notification object: https://docs.wonderpush.com/reference/notification
