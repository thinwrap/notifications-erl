# Brevo Connector (Erlang)

Email via the Brevo (formerly Sendinblue) transactional HTTP API over direct
HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => brevo` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => brevo,
    api_key => fun() -> env("BREVO_KEY") end,
    from => <<"noreply@example.com">>
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_email(Config, #{
        to => <<"user@example.com">>, subject => <<"Hi">>, html => <<"<p>Hi</p>">>
    }).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `secret()` | yes | Sent in the `api-key` header (**NOT** `Authorization: Bearer …`) |
| `from` | `binary()` | no | Default sender (Brevo's `sender.email`); a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Composed alongside `from` as `sender: {name, email}` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get an API key at Brevo → SMTP & API → API keys. Sent in the `api-key` request
header. Static.

## Endpoint

`POST https://api.brevo.com/v3/smtp/email` — single global endpoint.

## Narrowed input augmentations

`from` (+ `sender_name`) → `sender` (`{email, name?}`); `to` → `to`
(`[{email}]`); `subject` → `subject`; `cc`/`bcc` → `cc`/`bcc` (`[{email}]`);
`html`/`text` → `htmlContent`/`textContent`; `reply_to` → `replyTo` (`{email}`);
`headers` → `headers` (flat map); `tags` → `tags` (array); `attachments` →
`attachment` (`{name, content(base64)}`). `status` is `sent`;
`provider_message_id` comes from `messageId`. **Pre-flight guard:** any
attachment with a `content_id` returns `{error, #{code := invalid_request}}` before any HTTP call — Brevo's
`/v3/smtp/email` has no inline cid mechanism.

Keys ride **verbatim** in `passthrough.body` (no casing transform — Brevo's wire
shape is already camelCase). Common keys: `templateId`, `params`,
`messageVersions`, `scheduledAt`, `batchId`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 402 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 400 | message matches `recipient` / `to[` / `email address` / `sender` | `invalid_recipient` |
| 400 | (other) | `invalid_request` |
| 404 | (any) | `invalid_request` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_email(Config, #{
    to => <<"user@example.com">>,
    subject => <<"unused for template">>,
    html => <<"<p>fallback</p>">>,
    passthrough => #{body => #{
        <<"templateId">> => 9,
        <<"params">> => #{<<"name">> => <<"Alice">>}
    }}
}).
```

## Vendor docs

- API reference: https://developers.brevo.com/reference/send-transac-email
- Templates: https://developers.brevo.com/docs/send-a-transactional-email
- Rate limits: https://developers.brevo.com/docs/api-limits
