# Infobip Connector (Erlang)

Infobip SMS via direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => infobip` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => infobip,
    base_url => <<"xyz123.api.infobip.com">>,
    api_key => fun() -> env("INFOBIP_API_KEY") end,
    from => <<"Acme">>
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `base_url` | `binary()` | yes | Per-account subdomain (e.g. `<<"xyz123.api.infobip.com">>`); the connector prepends `https://`. It must be a bare DNS hostname — a scheme, path, port, userinfo, trailing slash or trailing newline returns `{error, #{code := invalid_request}}` before any request, and the message does not repeat the value |
| `api_key` | `secret()` | yes | Sent via Infobip's custom `Authorization: App <apiKey>` scheme |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set, validated at send) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Infobip provisions a **customer-specific base URL** at account creation, so
`base_url` is required. The API key is sent via the custom
`Authorization: App <apiKey>` scheme (not Bearer, not Basic).

## Endpoint

`POST https://<base_url>/sms/2/text/advanced` — JSON body.

## Narrowed input augmentations

The v2 advanced endpoint takes a `messages` array even for one message. The
connector builds `messages: [{from, destinations: [{to}], text}]` from `from`
(per-send or config, **required**), `to` and `body`. A missing sender returns
`{error, #{code := invalid_request}}` before any request. On success `status`
is `sent` and `provider_message_id` comes from `messages[0].messageId`.

Infobip answers **HTTP 200 even when it rejects the message**
(`messages[0].status.groupId == 5`, group `REJECTED`). That returns
`{error, #{status := 200}}` with the full response in `cause`'s `<<"raw">>` —
see the error mapping below.

Infobip's wire keys are already camelCase and `passthrough.body` merges
**verbatim** (no casing transform). Top-level request fields (`bulkId`,
`tracking`, `sendingSpeedLimit`, `includeSmsCountInResponse`, …) merge
directly; per-message fields (`sendAt` for scheduling, `callbackData`,
`notifyUrl`, `validityPeriod` in minutes, `flash`,
`language: #{<<"languageCode">> => …}`, `transliteration`, …) require
overriding the `messages` key (a list replaces, it does not merge).

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| other ≥400 | (any) | `invalid_request` |
| 200 | REJECTED, name contains `DESTINATION` / `PREFIX` / `MISSING_TO` / `DND` / `NOT_REGISTERED` | `invalid_recipient` |
| 200 | REJECTED `REJECTED_FLOODING_FILTER` | `rate_limited` |
| 200 | other REJECTED (e.g. `REJECTED_SENDER`, `REJECTED_NOT_ENOUGH_CREDITS`) | `invalid_request` |

The error body shape is `{requestError:{serviceException:{messageId,text}}}`;
the `EC_*` `messageId` is kept in `cause` but not individually mapped — the HTTP
status drives classification. When the vendor sends `Retry-After` (typically
on 429), the error's `cause` carries the raw header under `<<"retryAfter">>`
and its parsed seconds under `<<"retryAfterSeconds">>`, next to the decoded
body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{body => #{<<"bulkId">> => <<"batch-77">>}}
}).
```

## Vendor docs

- API reference: https://www.infobip.com/docs/api/channels/sms/sms-api/send-sms-message
- Account base URL: https://www.infobip.com/docs/essentials/base-url
