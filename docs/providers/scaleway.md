# Scaleway Transactional Email (TEM) Connector (Erlang)

Email via the Scaleway TEM HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies). EU-sovereign: regions are physically EU-resident (`fr-par`,
`nl-ams`, `pl-waw`).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => scaleway` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => scaleway,
    secret_key => fun() -> env("SCW_SECRET_KEY") end,
    project_id => env("SCW_PROJECT_ID"),
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
| `secret_key` | `secret()` | yes | Scaleway IAM API secret key, sent verbatim in the `X-Auth-Token` header |
| `project_id` | `binary()` | yes | Written as the `project_id` wire field on every send |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Composed into `from.name` |
| `region` | `binary()` | no | Default `fr-par`; interpolated into the endpoint **path** (not a host swap), so it must look like a Scaleway region id (`<cc>-<city>`, e.g. `fr-par`) or `{error, #{code := invalid_request}}` is returned before sending. Transactional Email currently runs in `fr-par` only |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Generate an API key (Access key + Secret key) under Scaleway IAM. Only the
**secret key** is used here, sent verbatim in the `X-Auth-Token` header. Static.

## Endpoint

`POST https://api.scaleway.com/transactional-email/v1alpha1/regions/{region}/emails`
(one host for every region; `{region}` defaults to `fr-par`).

## Narrowed input augmentations

`from` (+ `sender_name`) → `from` (`{email, name?}`); `to` → `to` (`[{email}]`);
`subject` → `subject`; `project_id` → `project_id`; `cc`/`bcc` → `cc`/`bcc`
(`[{email}]`); `text`/`html` → `text`/`html`; `headers` → `additional_headers`
(`[{key, value}]`); `reply_to` folded into `additional_headers` as a `Reply-To`
entry (no first-class field); `attachments` → `attachments`
(`{name, type, content(base64)}`; empty `content_type` defaults to
`application/octet-stream`). `status` is `queued` (Scaleway accepts
for delivery asynchronously); `provider_message_id` comes from
`emails[0].message_id` (falling back to `emails[0].id`). **Graceful
degradation:** `tags` and attachment `content_id` have no Scaleway field at v1.0
and are silently dropped.

Keys ride in `passthrough.body` and are rewritten to **snake_case**, e.g.
`scheduledAt` → `scheduled_at`. Only TOP-LEVEL names are rewritten; nested objects ride verbatim, so keys inside them are written as the vendor spells them.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| other 4xx (≥400) | (any) | `invalid_request` |
| (other) | — | `unknown` |

(Scaleway has no body-level error-code disambiguator; HTTP status is the sole
signal.)

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_email(Config, #{
    to => <<"user@example.com">>,
    subject => <<"Hi">>,
    html => <<"<p>Hi</p>">>,
    %% -> scheduled_at
    passthrough => #{body => #{<<"scheduledAt">> => <<"2026-06-03T09:00:00Z">>}}
}).
```

## Vendor docs

- API reference: https://www.scaleway.com/en/developers/api/transactional-email/
- Send an email: https://www.scaleway.com/en/docs/transactional-email/api-cli/send-emails-with-api/
- IAM API keys: https://www.scaleway.com/en/docs/transactional-email/how-to/generate-api-keys-for-tem-with-iam/
