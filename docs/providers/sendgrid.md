# SendGrid Connector (Erlang)

Email via the SendGrid v3 Mail Send HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => sendgrid` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => sendgrid,
    api_key => fun() -> env("SENDGRID_KEY") end,
    from => <<"noreply@example.com">>
},
{ok, #{status := queued, provider_message_id := Id}} =
    thinwrap_notifications:send_email(Config, #{
        to => <<"user@example.com">>, subject => <<"Hi">>, html => <<"<p>Hi</p>">>
    }).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `secret()` | yes | Bearer secret (typically starts with `SG.`) |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Sender display name (sent as `from.name`) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Generate an API key with at minimum **Mail Send** permission at
https://app.sendgrid.com/settings/api_keys. Sent as `Authorization: Bearer
<api_key>` on every request. Static — no refresh, no token caching.

## Endpoint

`POST https://api.sendgrid.com/v3/mail/send` — single global endpoint.

## Narrowed input augmentations

`to`/`cc`/`bcc` → `personalizations[0].to`/`.cc`/`.bcc` (each `{email}`);
`from` (+ `sender_name`) → `from` (`{email, name?}`); `subject` → `subject`;
`text` then `html` → `content` (`[{type, value}]`); `reply_to` → `reply_to`
(`{email}`); `headers` → `headers`; `tags` → `categories`; `attachments` →
`attachments` (`{content(base64), filename, type?}`; `content_id` adds
`content_id` + `disposition:"inline"`). The 202 Accepted has an empty body:
`status` is `queued`, `provider_message_id` comes from the
`X-Message-Id` response header, and `raw` is `#{<<"messageId">> => Id}`.

Keys ride in `passthrough.body`; only their TOP-LEVEL names are rewritten to
**snake_case** (e.g. `templateId` → `template_id`, `sendAt` → `send_at`).
Nested objects are never recased, so keys inside them must be SendGrid's own:
template data goes in `personalizations[].dynamic_template_data`. Common keys:
`template_id`, `personalizations`, `categories`, `send_at`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 413 | (any) | `invalid_request` |
| 400 | first error `field` = `from.email` / `reply_to` / `reply_to.email` / `personalizations…`, or message contains `email address` | `invalid_recipient` |
| 400 | (other) | `invalid_request` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_email(Config, #{
    to => <<"user@example.com">>,
    subject => <<"Welcome">>,
    html => <<"<p>fallback</p>">>,
    passthrough => #{body => #{
        %% top-level key -> template_id
        <<"templateId">> => <<"d-xxxxxxxxxxxx">>,
        <<"personalizations">> => [#{
            <<"to">> => [#{<<"email">> => <<"user@example.com">>}],
            <<"dynamic_template_data">> => #{<<"name">> => <<"Alice">>}
        }]
    }}
}).
```

## Vendor docs

- API reference: https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send
- Error responses: https://www.twilio.com/docs/sendgrid/api-reference/how-to-use-the-sendgrid-v3-api/responses
- Rate limits: https://www.twilio.com/docs/sendgrid/api-reference/how-to-use-the-sendgrid-v3-api/rate-limits
