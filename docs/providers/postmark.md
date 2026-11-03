# Postmark Connector (Erlang)

Email via the Postmark HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => postmark` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => postmark,
    server_token => fun() -> env("POSTMARK_TOKEN") end,
    from => <<"noreply@example.com">>,
    message_stream => <<"outbound">>
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_email(Config, #{
        to => <<"user@example.com">>, subject => <<"Hi">>, html => <<"<p>Hi</p>">>
    }).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `server_token` | `secret()` | yes | Sent in the `X-Postmark-Server-Token` header |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Display name composed as `Name <addr>`: quoted when it holds specials such as `,` (`"Joe Sender, Jr." <addr>`), RFC 2047 encoded-words when non-ASCII. A `from` already written as `Name <addr>` is parsed: its own name wins over `sender_name` and is encoded the same way, so angle brackets never nest. |
| `message_stream` | `binary()` | no | Default stream (e.g. `outbound`, `broadcasts`); per-send override via the passthrough body key `<<"messageStream">>` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get a server-level token from the Postmark account ("Servers → API tokens").
Sent in the `X-Postmark-Server-Token` header. Static.

## Endpoint

`POST https://api.postmarkapp.com/email`, or
`POST https://api.postmarkapp.com/email/withTemplate` for a template send (see
below).

## Narrowed input augmentations

The body is hand-built in Postmark **PascalCase**: `from` (+ `sender_name`) →
`From`; `to` → `To`; `subject` → `Subject`; `cc`/`bcc` → `", "`-joined
`Cc`/`Bcc`; `html`/`text` → `HtmlBody`/`TextBody`; `reply_to` → `ReplyTo`;
`headers` → `Headers` (`[{Name, Value}]`); `tags` → `Tag` (**first-tag-wins**,
remainder dropped — Postmark accepts one); `message_stream` from config;
`attachments` → `Attachments` (`{Name, Content(base64), ContentType?}`;
`content_id` becomes `ContentID: "cid:"+<id>`). `status` is `sent`;
`provider_message_id` comes from `MessageID`. A 200 OK with `ErrorCode != 0` is
re-surfaced as an error (mapped as status 422).

Keys ride in `passthrough.body` and their TOP-LEVEL names are rewritten to
**PascalCase**, e.g. `trackOpens` → `TrackOpens`; nested objects (such as
`Metadata`) ride verbatim. Common keys: `Metadata`, `TrackOpens`, `TrackLinks`,
and a per-send `MessageStream` override.

**Templates.** Postmark sends templates only through `POST /email/withTemplate`.
When the merged body carries a `TemplateId` or a non-empty `TemplateAlias` (e.g.
`passthrough => #{body => #{<<"templateId">> => 1234567, <<"templateModel">> => #{...}}}`), the
connector posts there instead of `/email`, drops `Subject` / `HtmlBody` /
`TextBody` (the template generates them from `TemplateModel`), and sends
`TemplateModel => #{}` when none (or `null`) is given.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal (`ErrorCode`) | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 422 | 406 (inactive recipient) | `invalid_recipient` |
| 422 | 300 (send validation) about an invalid `'To'` / `'Cc'` / `'Bcc'` address | `invalid_recipient` |
| 422 | 10, 412 (pending account: recipients must share the From domain), 413 (account not approved), 422 (invalid server/account), 1480 (IP not authorized), 405 (legacy) | `auth_failed` |
| 422 | 300 (other, incl. "Zero recipients specified" and From errors), 402, 403, 410, 411 (attachment type), 1101, 1235, 1236, (other) | `invalid_request` |
| other 4xx (404, 413, 415, …) | (any) | `invalid_request` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_email(Config, #{
    to => <<"user@example.com">>,
    subject => <<"Receipt">>,
    html => <<"<p>Thanks!</p>">>,
    passthrough => #{body => #{
        %% top-level key -> TrackOpens
        <<"trackOpens">> => true,
        <<"Metadata">> => #{<<"orderId">> => <<"12345">>}
    }}
}).
```

## Vendor docs

- API reference: https://postmarkapp.com/developer/api/email-api
- Templates (`/email/withTemplate`): https://postmarkapp.com/developer/api/templates-api
- Error codes: https://postmarkapp.com/developer/api/overview#error-codes
- Rate limits: https://postmarkapp.com/developer/api/overview#rate-limiting
