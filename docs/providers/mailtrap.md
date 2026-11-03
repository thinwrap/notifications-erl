# Mailtrap Connector (Erlang)

Email via the Mailtrap Sending HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies). Supports both production delivery and the sandbox capture
inbox.

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => mailtrap` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => mailtrap,
    api_token => fun() -> env("MAILTRAP_TOKEN") end,
    %% REQUIRED — <<"production">> or <<"sandbox">>
    mode => <<"production">>,
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
| `api_token` | `secret()` | yes | Bearer credential |
| `mode` | `binary()` | yes | `"sandbox"` or `"production"` — no default (the sandbox↔production failure mode is asymmetric); validated at send time |
| `inbox_id` | `binary()` | conditional | REQUIRED when `mode == "sandbox"`, FORBIDDEN when `mode == "production"` |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Default sender display name (sent as `from.name`) |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Get an API token at Mailtrap → Sending Domains → API tokens. Sent as
`Authorization: Bearer <api_token>`. Static.

## Endpoint

Mode-derived (validated pre-flight; an invalid `mode`/`inbox_id` combination
returns `{error, #{code := invalid_request}}`
before any HTTP call):
- `production`: `POST https://send.api.mailtrap.io/api/send`
- `sandbox`: `POST https://sandbox.api.mailtrap.io/api/send/<inbox_id>` (`inbox_id` is percent-encoded as one path segment)

## Narrowed input augmentations

`from` (+ `sender_name`) → `from` (`{email, name?}`); `to` → `to` (`[{email}]`);
`subject` → `subject`; `cc`/`bcc` → `cc`/`bcc` (`[{email}]`); `reply_to` →
`reply_to` (a **single object** `{email}`); `html`/`text` → `html`/`text`;
`headers` → `headers` (a flat map); `attachments` → `attachments`
(`{filename, content(base64), type?}`; `content_id` adds `content_id` +
`disposition:"inline"`). `status` is `sent`; `provider_message_id`
comes from `message_ids[0]`. A non-empty `tags` is **rejected pre-flight** with
`{error, #{code := invalid_request}}` — Mailtrap has no tags at v1.0 (use the
passthrough body key `<<"category">>`).

Keys ride in `passthrough.body` and are rewritten to **snake_case**, e.g.
`templateUuid` → `template_uuid`, `templateVariables` → `template_variables`,
`customVariables` → `custom_variables`, `category`. Only TOP-LEVEL names are rewritten; nested objects ride verbatim, so keys inside them are written as the vendor spells them.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 422 / 400 | any `errors[]` entry matches `recipient` / `email` / `to ` / `from address` | `invalid_recipient` |
| 422 / 400 | (other) | `invalid_request` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_email(Config, #{
    to => <<"user@example.com">>,
    subject => <<"unused">>,
    html => <<"<p>fallback</p>">>,
    passthrough => #{body => #{
        <<"templateUuid">> => <<"abcdef-123">>,
        <<"templateVariables">> => #{<<"name">> => <<"Alice">>}
    }}
}).
```

## Vendor docs

- API reference: https://docs.mailtrap.io/developers
- Sandbox guide: https://docs.mailtrap.io/email-sandbox/setup/sandbox-api-integration
