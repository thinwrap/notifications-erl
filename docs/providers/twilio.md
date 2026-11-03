# Twilio Connector (Erlang)

Twilio SMS via direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => twilio` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => twilio,
    account_sid => env("TWILIO_ACCOUNT_SID"),
    auth_token => fun() -> env("TWILIO_AUTH_TOKEN") end,
    from => <<"+15550000000">>
},
case thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}) of
    {ok, #{status := sent, provider_message_id := Sid}} -> {sent, Sid};
    {error, #{code := Code} = Err} -> {failed, Code, maps:get(status, Err, none)}
end.
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `account_sid` | `binary()` | yes | Account SID (Basic-auth username and a URL path segment, percent-escaped) |
| `auth_token` | `secret()` | yes | Auth token (Basic-auth password) |
| `from` | `binary()` | no | Default sender (E.164 or short code); a per-send `from` overrides it. Omit only when a `messagingServiceSid` passthrough is supplied |
| `region` | `binary()` | no | REST processing region: `<<"us1">>` (default), `<<"ie1">>` or `<<"au1">>`. Twilio's legacy ids `br1`/`de1`/`jp1`/`sg1`/`us2` are edge locations that process in `us1`, so they are rejected — pick the edge with `edge` instead |
| `edge` | `binary()` | no | Edge location: `sydney`, `sao-paulo`, `dublin`, `frankfurt`, `tokyo`, `singapore`, `ashburn`, `umatilla` or `roaming`. Defaults to `dublin` for `ie1`, `sydney` for `au1`, and none for `us1` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get the Account SID and Auth Token from the Twilio Console. They are sent as
HTTP Basic auth (`Authorization: Basic base64(sid:token)`).

## Endpoint

`POST https://<host>/2010-04-01/Accounts/<account_sid>/Messages.json` —
`application/x-www-form-urlencoded`. `<host>` is `api.twilio.com` for `us1`
without an edge, else `api.<edge>.<region>.twilio.com` — for example
`api.dublin.ie1.twilio.com`, `api.sydney.au1.twilio.com`,
`api.frankfurt.us1.twilio.com`. Twilio retired the `api.<region>.twilio.com`
form on 2026-04-28 and requires the edge in the host for non-US regions. An
unknown `region` or `edge` returns `{error, #{code := invalid_request}}` before
any request is sent.

The region decides where Twilio processes the request, and only for the
products Twilio offers there. Twilio's
[regional product availability](https://www.twilio.com/docs/global-infrastructure/regional-product-and-feature-availability)
page lists Programmable Messaging for IE1 but not for AU1, so check Messaging
support in AU1 on your account before relying on `au1`. The connector does not
make any data-residency guarantee.

## Narrowed input augmentations

`to` → `To`; `body` → `Body`; `from` (per-send or config) → `From`. Either a
`from` or a `messagingServiceSid` passthrough is required (else
`{error, #{code := invalid_request}}`, no request sent). On success `status`
is `sent` and `provider_message_id` comes from the response `sid`.

Twilio is one of the seven casing connectors: the **top-level**
`passthrough.body` keys are rewritten to Twilio's **PascalCase**
(`messagingServiceSid` → `MessagingServiceSid`, `media_url` → `MediaUrl`,
`statusCallback` → `StatusCallback`). A list value becomes a repeated form
field (`MediaUrl`); a map value is sent as JSON (`ContentVariables`), and its
keys ride verbatim.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 400 | `code` 21211 / 21408 / 21610 / 21612 / 21614 | `invalid_recipient` |
| 400 | `code` 20003 | `auth_failed` |
| other ≥400 | (any) | `invalid_request` |
| (other) | — | `unknown` |

The vendor `code` and `message` are read from the JSON error body. When the
vendor sends `Retry-After` (typically on 429), the error's `cause` carries the
raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"See attached">>,
    passthrough => #{
        body => #{
            mediaUrl => [<<"https://example.com/a.jpg">>],
            statusCallback => <<"https://example.com/status">>
        }
    }
}).
```

## Vendor docs

- API reference: https://www.twilio.com/docs/messaging/api/message-resource
- Error codes: https://www.twilio.com/docs/api/errors
- Regions: https://www.twilio.com/docs/global-infrastructure/edge-locations
