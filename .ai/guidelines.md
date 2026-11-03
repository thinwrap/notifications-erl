# `thinwrap_notifications` (Erlang) — contributor guide

This folder (`.ai/`) is for developers — and the coding agents working alongside
them — who are **changing this library**. It is not usage documentation.

> **Using the package?** See the module docs of `thinwrap_notifications` and the
> per-provider pages under [`../docs/providers/`](../docs/providers). `.ai/` is
> contributor-only.

## Map of this folder

- **guidelines.md** (this file) — entry point + the "add a provider" recipe.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — public module → provider module → shared HTTP seam, and the invariants.
- [`CONVENTIONS.md`](./CONVENTIONS.md) — data shapes, error handling, naming, testing.

## The shape in one sentence

A consumer calls `thinwrap_notifications:send_<channel>(Config, Input)`
(`send_email`, `send_sms`, `send_push`, `send_chat`); the config's `provider`
key selects a provider module (`thinwrap_notifications_<provider>`), whose
`send/2` builds the request, sends it through `thinwrap_notifications_http`
(the injectable transport + transport-error normalization), and normalizes the
answer into `#{success, status, provider_message_id, raw}`. No global
middleware.

## Setup & verify

```bash
rebar3 compile
rebar3 do eunit, cover        # ≥80% total line coverage
rebar3 xref
rebar3 dialyzer
rebar3 lint                   # Elvis style policy (elvis.config)
rebar3 hank                   # dead code
scripts/eqwalize.sh           # eqWAlizer over src/ (needs Java 11+ and ELP)
rebar3 fmt --check            # erlfmt
```

`scripts/eqwalize.sh` runs eqWAlizer through ELP (`brew install
erlang-language-platform`), whose checker needs Java 11+ on `PATH` — on macOS
with Homebrew's JDK: `PATH=/opt/homebrew/opt/openjdk/bin:$PATH scripts/eqwalize.sh`.

OTP ≥ 27 (the stdlib `json` module). **Zero runtime dependencies — do not add
any.** HTTP is OTP `httpc` behind a behaviour; JSON is OTP `json`; SigV4 is
hand-rolled on `crypto` (`thinwrap_notifications_sigv4`); JWT signing for
FCM (RS256) and APNs (ES256) goes on `public_key`/`crypto` — never a JOSE
library.

## Add a provider

The Python sibling (`../notifications-py/src/thinwrap/notifications/_<provider>.py`)
is the reference port: same requests, same normalization, same error mapping.
The provider is ALREADY registered everywhere except its own module: its
config keys, channel, dispatch entry and support-table row exist. So adding one
is:

1. **Provider module** — `src/thinwrap_notifications_<provider>.erl`, named
   after the Python module without its underscore (`_onesignal.py` →
   `thinwrap_notifications_onesignal`; the exact name is in
   `provider_module/1` in `thinwrap_notifications.erl`). `-moduledoc false`,
   `-behaviour(thinwrap_notifications_provider)`, exporting `send/2`
   (`Config`, `Input`) with `-doc false` and a `-spec`. Vendor error mapping
   (`map_code`) and response navigation are private functions in the same
   module. Copy the closest email module as a template:
   - plain JSON + bearer: `thinwrap_notifications_resend` / `_sendgrid`
   - form POST + Basic auth, ordered fields: `thinwrap_notifications_mailgun`
     (`passthrough:merge_form/2` + `http:send_post_form/5`)
   - SigV4 (SNS): `thinwrap_notifications_ses` + `thinwrap_notifications_sigv4`
   - top-level passthrough casing (Twilio = `pascal`): `_postmark`
2. **Nothing else in `src/`** unless the Python module needs a new shared
   helper. The config keys come from `?PROVIDERS` in
   `thinwrap_notifications_input.erl` — check them against the Python
   `<Name>Config` dataclass, and fix the table (not your module) if they
   disagree. Dispatch, `supports/2` and `providers/1` need no change.
3. **Tests** — `test/thinwrap_notifications_<provider>_tests.erl` (eunit),
   ported from the Python `tests/test_<provider>.py`, plus that provider's
   cases from the cross-cutting Python files (`test_core.py`,
   `test_passthrough_casing.py`, `test_request_guards.py`,
   `test_signing_leak.py`). Use `thinwrap_notifications_fake_transport:config/2`.
   `core_tests:not_yet_implemented_provider_test` skips a provider once its
   module loads — no edit needed there.
4. **Docs** — `docs/providers/<python-doc-name>.md` adapted from
   `../notifications-py/docs/providers/` with Erlang examples (see an email
   page for the shape).

### Channel notes for phases 2 and 3

- **SMS** (vonage, twilio, plivo, sns, sinch, telnyx, infobip, messagebird,
  textmagic, d7networks). Input `#{to, body, from, passthrough}`, all
  defaulted. Form vendors (Twilio, Vonage, TextMagic) build an ordered
  `[{binary(), term()}]` field list and use `passthrough:merge_form/2`; a list
  value repeats the field (Twilio `MediaUrl`), a map becomes JSON. Twilio is
  one of the seven casing connectors (`pascal`). Config path segments go
  through `thinwrap_notifications_util:quote(Value, Safe)` (Python
  `quote(v, safe=...)`). SNS reuses `thinwrap_notifications_sigv4` exactly as
  SES does (form body, signed `Content-Type`).
- **Push** (fcm, expo, apns, one-signal, pusher-beams, wonderpush). Input
  `#{to, title, body, data, passthrough}`. FCM/APNs read the optional
  `token_cache` through `thinwrap_notifications_token_cache:lookup/2` and
  `store/4` (key formats and TTLs from the Python modules); the cache is
  validated by the input module. Port `_crypto.py`'s RS256/ES256 onto
  `public_key:sign/3` (PEM via `public_key:pem_decode/1` + `pem_entry_decode/1`;
  ES256 needs the DER signature converted to raw `r||s`, 64 bytes). A key
  that fails to parse/sign must become `auth_failed` with only the failure
  kind in `cause` — wrap the signing in `try … catch` and never let the
  exception (whose stacktrace args hold the PEM) escape; see
  `test_signing_leak.py`.
- **Chat** (telegram, slack, whatsapp-business, discord, ms-teams,
  google-chat, mattermost, rocket-chat, line). Input `#{body, to,
  passthrough}`. Webhook URLs are credentials: call
  `thinwrap_notifications_error:assert_webhook_https(Url, <<"Slack">>)` first
  where the Python module calls `assert_webhook_https`. Telegram's bot token is
  a path segment: `quote(Token, <<":">>)`.
- **Response values** that become `provider_message_id` go through
  `thinwrap_notifications_util:response_text/1` when the Python module uses
  `response_text` (never crash after an accepted send).
- **NaN/Infinity** tests have no Erlang equivalent (BEAM floats are finite and
  OTP's decoder rejects those tokens); skip them and list them in your report.

### Definition of done (the CI gates)

```bash
rebar3 fmt && rebar3 do eunit, cover && rebar3 xref && rebar3 dialyzer && rebar3 lint \
  && rebar3 hank && scripts/eqwalize.sh && rebar3 fmt --check
```

## Invariants you must not break

- **Zero runtime deps / no vendor SDKs.**
- **Stateless wrapper.** No caching, retries, idempotency keys, telemetry, and
  no processes, ETS tables or application env. FCM/APNs sign fresh on every
  send unless the caller passes a `token_cache`; nothing is evicted on 401/403.
- **≥90% baseline-coverage rule.** A field belongs on a channel input only if
  ≥90% of that channel's providers support it; everything else goes to
  `passthrough` (input) / `raw` (output), or lives on the provider config.
- **Per-connector locality.** `map_code`, casing transforms and any outlier
  translation live in the provider module — never in `thinwrap_notifications_http`.
- **Six error codes** — the sibling `ProviderCode` values as atoms. The raw
  `Retry-After` rides in `cause` as `<<"retryAfter">>` (+ `<<"retryAfterSeconds">>`);
  there is no top-level retry field.
- **Passthrough keys ride as given**, except the seven casing connectors
  (Postmark, Twilio = pascal; Mailtrap, SparkPost, SendGrid, MailerSend,
  Scaleway = snake) — top level only. Do not add casing anywhere else.
- **Two kinds of failure** — send failures are `{error, connector_error()}`;
  misuse raises `{badarg, Description}`. See CONVENTIONS.
