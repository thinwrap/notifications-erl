# Expo Connector (Erlang)

Expo push over direct HTTP (OTP only — no vendor SDK, no runtime
dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => expo` to
`thinwrap_notifications:send_push/2`:

```erlang
Config = #{
    provider => expo,
    access_token => fun() -> list_to_binary(os:getenv("EXPO_ACCESS_TOKEN")) end  % optional
},
case thinwrap_notifications:send_push(Config, #{
    to => <<"ExponentPushToken[xxx]">>, title => <<"Hi">>, body => <<"Hello">>
}) of
    {ok, #{status := sent, provider_message_id := TicketId}} -> {sent, TicketId};
    {error, #{code := Code} = Err} -> {failed, Code, maps:get(status, Err, none)}
end.
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `access_token` | `secret()` | no | Optional Expo access token; when set (non-empty) it is sent verbatim as `Authorization: Bearer <token>`. Long-lived per-project key — no refresh, no caching |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Expo accepts unauthenticated requests for projects that allow them. For
enhanced-security projects, create an access token in the Expo dashboard; it is
sent as `Authorization: Bearer <token>` only when set.

## Endpoint

`POST https://exp.host/--/api/v2/push/send` — single global endpoint, JSON
body. `passthrough.query` is not forwarded.

## Narrowed input augmentations

`to` → `to`; `title` → `title`; `body` → `body`; `data` → `data` (empty ones
omitted, `to` always sent). On success `status` is `sent` and
`provider_message_id` comes from the ticket `id` (Expo's `data` field is
normalized from either a single ticket object or an array to the first
ticket; a response with no ticket is `unknown`).

Expo returns **HTTP 200 even for soft errors**: a ticket with `status` `"error"`
maps to an error via the ticket-error table below (with `status => 200`).

Expo's API is camelCase-native, so `passthrough.body` merges **verbatim** (no
casing transform): `badge`, `sound`, `ttl`, `priority`, `channelId`,
`categoryId`, `mutableContent`, `subtitle`, `interruptionLevel`,
`_displayInForeground`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

HTTP layer (message: `errors[0].message`, else `Expo HTTP <status>`):

| Vendor HTTP | `code` |
|---|---|
| 401 | `auth_failed` |
| 429 | `rate_limited` |
| ≥500 | `provider_unavailable` |
| other ≥400 | `invalid_request` |
| (otherwise) | `unknown` |

Body-layer ticket error (HTTP 200, `data[].details.error`; message: the ticket
`message`, else `Expo ticket error: <code>`):

| Ticket error | `code` |
|---|---|
| DeviceNotRegistered | `invalid_recipient` |
| MessageTooBig | `invalid_request` |
| MessageRateExceeded | `rate_limited` |
| MismatchSenderId / InvalidCredentials | `auth_failed` |
| (unmapped) | `unknown` |

When the vendor sends `Retry-After` on an HTTP error (typically 429), the
error's `cause` carries the raw header under `<<"retryAfter">>` and its parsed
seconds under `<<"retryAfterSeconds">>`, next to the decoded body under
`<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_push(Config, #{
    to => <<"ExponentPushToken[xxx]">>,
    title => <<"Hi">>,
    body => <<"Hello">>,
    passthrough => #{
        body => #{<<"sound">> => <<"default">>, <<"badge">> => 1, <<"priority">> => <<"high">>}
    }
}).
```

## Vendor docs

- API reference: https://docs.expo.dev/push-notifications/sending-notifications/
- Errors: https://docs.expo.dev/push-notifications/sending-notifications/#push-receipt-errors
