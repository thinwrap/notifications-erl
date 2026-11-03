# SparkPost Connector (Erlang)

Email via the SparkPost Transmissions HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => sparkpost` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => sparkpost,
    api_key => fun() -> env("SPARKPOST_KEY") end,
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
| `api_key` | `secret()` | yes | Sent **verbatim** in `Authorization` (no `Bearer`/`Basic` prefix) |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Composed alongside `from` |
| `region` | `binary()` | no | `"eu"` → `api.eu.sparkpost.com`; `""`/`"us"` → `api.sparkpost.com` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get an API key at SparkPost → Account → API keys with `Transmissions:
Read/Write`. Sent verbatim in the `Authorization` header (no prefix — SparkPost
is an outlier). Static.

## Endpoint

Region-derived:
- `""`/`us` (default): `POST https://api.sparkpost.com/api/v1/transmissions`
- `eu`: `POST https://api.eu.sparkpost.com/api/v1/transmissions`

## Narrowed input augmentations

`from` (+ `sender_name`) → `content.from` (`{email, name?}`); `subject` →
`content.subject`; `html`/`text` → `content.html`/`.text`; `reply_to` →
`content.reply_to` (a **string**); `headers` → `content.headers`; `attachments`
→ `content.attachments` (`{name: filename, type, data(base64)}`) or, when
`content_id` is set, `content.inline_images` (`{name: content_id, type, data}` —
SparkPost puts `name` in the image's `Content-ID` header, so HTML references it
as `cid:<content_id>`). `type` is required by SparkPost and defaults to
`application/octet-stream`; `tags` → `metadata.tags`. **CC/BCC outlier:** SparkPost
has no `cc`/`bcc` fields — `to` seeds `recipients[]`, and each `cc`/`bcc` is
appended to `recipients[]` with `address.header_to` set to the primary `to`; CC
visibility comes from `content.headers.CC` (comma-joined), BCC stays invisible.
`status` is `queued`; `provider_message_id` comes from `results.id`. A
2xx that rejected **all** recipients (`total_accepted_recipients == 0 &&
total_rejected_recipients > 0`) is surfaced as an `invalid_recipient` error.

Keys ride in `passthrough.body` and are rewritten to **snake_case**, e.g.
`campaignId` → `campaign_id`, `substitutionData` → `substitution_data`,
`options`, `metadata`. Only TOP-LEVEL names are rewritten; nested objects ride verbatim, so keys inside them are written as the vendor spells them.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 420 (daily, monthly or sandbox sending limit), 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 413 / 422 | (any) | `invalid_request` |
| 400 | message matches `recipient` / `address`, or first-error `code` 1300/1301/1303 | `invalid_recipient` |
| 400 | (other) | `invalid_request` |
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
        <<"substitutionData">> => #{<<"name">> => <<"Alice">>},
        <<"options">> => #{<<"transactional">> => true}
    }}
}).
```

## Vendor docs

- API reference: https://developers.sparkpost.com/api/transmissions/
- EU endpoint: https://developers.sparkpost.com/api/index.html
- Rate limits: https://developers.sparkpost.com/api/index.html#header-rate-limiting
