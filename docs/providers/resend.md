# Resend Connector (Erlang)

Email via the Resend HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => resend` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => resend,
    api_key => fun() -> env("RESEND_KEY") end,
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
| `api_key` | `secret()` | yes | Bearer secret (typically starts with `re_`) |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Display name composed as `Name <addr>`: quoted when it holds specials such as `,`, RFC 2047 encoded-words when non-ASCII. A `from` already written as `Name <addr>` is parsed: its own name wins over `sender_name` and is encoded the same way, so angle brackets never nest. |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create an API key at https://resend.com/api-keys. Sent as
`Authorization: Bearer <api_key>` on every request. Static — no refresh.

## Endpoint

`POST https://api.resend.com/emails` — single global endpoint.

## Narrowed input augmentations

`from` (+ `sender_name`) → `from`; `to` → `to` (one-element array); `subject` →
`subject`; `html`/`text` → `html`/`text`; `cc`/`bcc` → `cc`/`bcc`; `reply_to` →
`reply_to`; `headers` → `headers`; `tags` → `tags` as
`[{name:"tag", value:<t>}]`; `attachments` → `attachments`
(`{filename, content(base64), content_type?, content_id?}`; a `content_id`
makes it an inline image referenced as `cid:<id>`). Tag names and values may
contain only ASCII letters, digits, `_` and `-` (max 256), so a tag with a
space, `:` or `.` is rejected by Resend with a 422. `status` is `sent`;
`provider_message_id` comes from the response `id`.

Keys ride in `passthrough.body` **exactly as given**: write Resend's snake_case
wire names, e.g. `scheduled_at`; `headers` (`{"X-Entity-Ref-ID": …}`) and `tags`
keep the caller's names. Use `passthrough.headers` for an
`Idempotency-Key`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 404 | (any) | `invalid_request` |
| 422 / 400 | message matches `recipient` / `email address` | `invalid_recipient` |
| 422 / 400 | (other) | `invalid_request` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_email(Config, #{
    to => <<"user@example.com">>,
    subject => <<"Hi">>,
    html => <<"<p>Hi</p>">>,
    passthrough => #{
        body => #{<<"scheduled_at">> => <<"2026-06-01T15:00:00.000Z">>},
        headers => #{<<"Idempotency-Key">> => <<"order-12345">>}
    }
}).
```

## Vendor docs

- API reference: https://resend.com/docs/api-reference/emails/send-email
- Idempotency: https://resend.com/docs/dashboard/emails/idempotency-keys
- Rate limits: https://resend.com/docs/api-reference/rate-limit
