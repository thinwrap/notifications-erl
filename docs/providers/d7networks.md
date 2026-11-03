# D7 Networks Connector (Erlang)

D7 Networks SMS via direct HTTP (OTP only — no vendor SDK, no runtime
dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => d7networks` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => d7networks,
    api_token => fun() -> env("D7_API_TOKEN") end,
    from => <<"SignOTP">>
},
{ok, #{status := sent, provider_message_id := RequestId}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_token` | `secret()` | yes | D7 API token (sent as a Bearer credential) |
| `from` | `binary()` | no | Default originator (alphanumeric or E.164); a per-send `from` overrides it (one must be set, validated at send) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create an API token in the D7 Networks dashboard. It is sent as
`Authorization: Bearer <api_token>` against a single global endpoint (no
regional clustering).

## Endpoint

`POST https://api.d7networks.com/messages/v1/send` — single global endpoint,
JSON body.

## Narrowed input augmentations

D7 has the most nested wire shape of any wrapped SMS provider. The connector
builds `messages: [{channel: "sms", recipients: [to], content: body,
msg_type: "text"}]` and `message_globals: {originator: <from>}` from `to`,
`body` and `from` (per-send or config, **required**). A missing originator
returns `{error, #{code := invalid_request}}` before any request. On success
`status` is `sent` and `provider_message_id` comes from the response
`request_id`.

Keys ride in `passthrough.body` **exactly as given** (write D7's snake_case
wire names): per-message `data_coding` / `msg_type` by overriding `messages`
(a list replaces, it does not merge); global `tag`, `schedule_time`,
`validity_period`, `report_url`, and an originator override via
`message_globals`, which deep-merges into the connector's map.

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

The error body shape is `{code,detail}`; the message is `detail`, else
`D7 Networks HTTP <status> <code>`, and the body is kept in `cause`. When the
vendor sends `Retry-After` (typically on 429), the error's `cause` carries the
raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{
        body => #{message_globals => #{report_url => <<"https://example.com/dlr">>}}
    }
}).
```

## Vendor docs

- API reference: https://d7networks.com/docs/sms/send-sms/
