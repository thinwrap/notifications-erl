# Mailgun Connector (Erlang)

Email via the Mailgun HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => mailgun` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => mailgun,
    api_key => fun() -> env("MAILGUN_KEY") end,
    domain => <<"mg.example.com">>,
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
| `api_key` | `secret()` | yes | Basic-auth password (username is `api` unless `username` is set) |
| `domain` | `binary()` | yes | Sending domain; forms the path `/v3/<domain>/messages` |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Display name composed as `Name <addr>`: quoted when it holds specials such as `,`, RFC 2047 encoded-words when non-ASCII. A `from` already written as `Name <addr>` is parsed: its own name wins over `sender_name` and is encoded the same way, so angle brackets never nest. |
| `region` | `binary()` | no | `"eu"` → `api.eu.mailgun.net`; anything else (default) → `api.mailgun.net`. Ignored when `base_url` is set |
| `username` | `binary()` | no | Basic-auth username; defaults to `api` |
| `base_url` | `binary()` | no | Explicit endpoint base (takes precedence over `region`); path is appended. Must be `https://` — the Basic credential rides on every request — else `{error, #{code := invalid_request}}` before sending |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get a Sending API key at https://app.mailgun.com/app/account/security/api_keys.
The connector sends `Authorization: Basic base64("api:<api_key>")`. Static.

## Endpoint

`POST <base_url>/v3/<domain>/messages` where `base_url` is `base_url`, else
`https://api.eu.mailgun.net` (region `eu`), else `https://api.mailgun.net`.

## Narrowed input augmentations

Sent as `application/x-www-form-urlencoded` (no attachments) or
`multipart/form-data` (with attachments). `from` (+ `sender_name`) → `from`;
`to` → `to`; `subject` → `subject`; `html`/`text` → `html`/`text`; `cc`/`bcc` →
comma-joined `cc`/`bcc`; `reply_to` → `h:Reply-To`; each `headers` entry →
`h:<Name>`. Header names are case-insensitive, so one `h:` field is sent per
name: a later `headers` entry wins over an earlier one differing only in case,
and `reply_to` wins over a `Reply-To` entry in `headers`. `tags` → repeated `o:tag` fields (**max 3**; extras truncated).
Attachments become `attachment` parts, or `inline` parts when `content_id` is set. Mailgun derives an inline image's Content-ID from the part's filename, so an inline part is sent with `filename=<content_id>` and the HTML references it as `cid:<content_id>`.
`status` is `queued` (Mailgun acknowledges queue acceptance, not
delivery); `provider_message_id` comes from the response `id`.

Keys ride **verbatim** in `passthrough.body` (no casing transform) — Mailgun's
wire keys are literal: `o:tag`, `o:deliverytime`, `o:tracking`, `v:<name>`,
`template`, `t:variables`, `h:X-Mailgun-Variables`. On both the form and the
multipart path a list value becomes repeated fields and a map becomes compact
JSON (Mailgun: `t:variables` is "A valid JSON-encoded dictionary").

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 402 / 403 ("Valid credentials but access denied") | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 400 | message matches `not a valid email` / `invalid recipient` / `invalid address` | `invalid_recipient` |
| 400 | (other) | `invalid_request` |
| 404 / 413 | (any) | `invalid_request` |
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
    passthrough => #{body => #{
        <<"o:tracking">> => <<"yes">>,
        <<"h:X-Mailgun-Variables">> => <<"{\"orderId\":\"12345\"}">>
    }}
}).
```

## Vendor docs

- API reference: https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages
- Regions: https://documentation.mailgun.com/docs/mailgun/api-reference/api-overview
- Rate limits: https://documentation.mailgun.com/docs/mailgun/api-reference/api-overview
