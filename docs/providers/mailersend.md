# MailerSend Connector (Erlang)

Email via the MailerSend HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => mailersend` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => mailersend,
    api_token => fun() -> env("MAILERSEND_TOKEN") end,
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
| `api_token` | `secret()` | yes | Bearer secret |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Default sender display name (sent as `from.name`) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Generate a token at MailerSend → Domains → API tokens. Sent as
`Authorization: Bearer <api_token>` (plus `X-Requested-With: XMLHttpRequest`).
Static.

## Endpoint

`POST https://api.mailersend.com/v1/email` — single global endpoint.

## Narrowed input augmentations

`from` (+ `sender_name`) → `from` (`{email, name?}`); `to` → `to` (`[{email}]`);
`subject` → `subject`; `cc`/`bcc` → `cc`/`bcc` (`[{email}]`); `reply_to` →
`reply_to` (a single object `{email}`); `html`/`text` → `html`/`text`;
`headers` → `headers` (`[{name, value}]`); `tags` → `tags` (**max 5**; extras
truncated); `attachments` → `attachments` (`{filename, content(base64)}`; `content_id` adds
`id` + `disposition:"inline"`; MailerSend has no content-type field, so
`content_type` is not sent). The 202
Accepted normally has an empty body: `status` is `queued`,
`provider_message_id` comes from the `X-Message-Id` response header, and `raw`
is `{"messageId": ...}`.

Suppressed recipients also come back as 202, with a `{message, warnings}` body:

- `SOME_SUPPRESSED` — the email is sent to the remaining recipients; the send
  succeeds and `raw` carries `message` and `warnings` alongside `messageId`.
- `ALL_SUPPRESSED` — the email is **not sent** (no `X-Message-Id`); returns
  `{error, #{code := invalid_recipient, status := 202}}` with the body in
  `cause` under `<<"raw">>`.

Keys ride in `passthrough.body` and are rewritten to **snake_case**, e.g.
`templateId` → `template_id`, `sendAt` → `send_at`, `inReplyTo` → `in_reply_to`,
`personalization`. Only TOP-LEVEL names are rewritten; nested objects ride verbatim, so keys inside them are written as the vendor spells them.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 422 | `errors` key `from.email` / `to.*` / `cc.*` / `bcc.*` / `reply_to.*` | `invalid_recipient` |
| 422 | other `errors` keys present | `invalid_request` |
| 422 | no field errors; message matches `recipient` / `email address` | `invalid_recipient` |
| 422 | (other) | `invalid_request` |
| 400 | (any) | `invalid_request` |
| 202 | `warnings[].type == "ALL_SUPPRESSED"` | `invalid_recipient` |
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
        <<"templateId">> => <<"abcdef">>,
        <<"personalization">> => [#{
            <<"email">> => <<"user@example.com">>,
            <<"data">> => #{<<"name">> => <<"Alice">>}
        }]
    }}
}).
```

## Vendor docs

- API reference: https://developers.mailersend.com/api/v1/email.html
- Rate limits: https://developers.mailersend.com/general.html#api-response
