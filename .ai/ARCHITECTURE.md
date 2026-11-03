# Architecture — `thinwrap_notifications` (Erlang)

## Public module → provider module → HTTP seam

```
thinwrap_notifications:send_email(Config, Input)
   │  thinwrap_notifications_input:config(email, Config)   badarg: keys, types, channel, transport
   │  thinwrap_notifications_input:input(email, Input)     badarg: keys, types; fills defaults
   ▼
thinwrap_notifications_sendgrid:send(Config, Input)        (provider module)
   │  builds body/headers, casing + passthrough merge
   ▼
thinwrap_notifications_http:send_post_json/5              (shared seam)
   │  URL + header guards (invalid_request), {Mod, Opts} = transport
   ▼
thinwrap_notifications_httpc (default) | caller's module  (transport behaviour)
```

- **One public module.** `thinwrap_notifications` exports `send_email/2`,
  `send_sms/2`, `send_push/2`, `send_chat/2`, `supports/2` and `providers/1`.
  It validates, dispatches, and converts a thrown connector error into
  `{error, Error}`. Nothing else is called by consumers except the
  `thinwrap_notifications_transport` behaviour (and `thinwrap_notifications_error:codes/0`).
- **Config-as-selector.** `#{provider => sendgrid, api_key => K}`; the provider
  atom picks the module. The provider table (`?PROVIDERS` in
  `thinwrap_notifications_input`) records each provider's channel, required
  and optional config keys, and which keys are credentials. It covers all 35
  providers of the Python sibling, so a phase that adds a provider adds only
  its module. A provider whose module is not yet in the build validates but
  fails with `error({provider_not_available, P})`.
- **Every provider serves one channel** (as in the Python registries); using it
  on another channel is misuse (`badarg`, the Python `ValueError`).
- **`thinwrap_notifications_http`** centralizes only the HTTP seam: request
  assembly (`send_get/4`, `send_post_json/5`, `send_post_form/5`,
  `send_post_raw/6`), case-insensitive header merge, the pre-flight guards
  the Python `BaseConnector` has (header name is an RFC 9110 token; value a
  binary/number/boolean without control characters and within Latin-1; URL
  without whitespace/controls/non-ASCII and with a valid port — each
  `invalid_request`), the transport call, and transport-failure
  normalization: any `{error, Reason}` or crash → `provider_unavailable`, no
  `status`, message `Upstream transport error (<kind>)`, cause
  `#{<<"raw">> => #{<<"exception">> => Kind}}` where `Kind` is only the
  reason's leading atom (the Python sibling keeps only the exception class
  name). A transport returning a malformed value raises
  `{bad_transport_return, Mod, Shape}` (caller bug, not an outage). No JSON
  parsing, no error mapping.

## Non-local failure

Connector code fails with `thinwrap_notifications_error:fail(Error)`, which
throws `{thinwrap_notifications_error, Error}`. Only the public module's
`call/3` catches it. This keeps provider code linear — the Python sibling
raises `ConnectorError` the same way — while the public surface stays
`{ok, _} | {error, _}`.

## Notifications-distinctive invariants

1. **Four channels, one operation each.** The result is
   `#{success := true, status := send_status(), provider_message_id := binary(), raw := term()}`;
   `status` is `sent | queued | rejected | suppressed | unknown`.
   `provider_message_id` is `<<>>` when the vendor gave none (the siblings'
   empty string); `raw` is the decoded body (`null` for an empty or non-JSON
   body, `#{}` where the Python connector substitutes `{}`).
2. **≥90% baseline coverage** on the channel inputs; provider-specific per-send
   fields flow through `passthrough`; provider-level settings live on the config.
3. **Passthrough keys ride as given**; seven connectors rewrite top-level
   `passthrough.body` keys (`thinwrap_notifications_casing`), nested maps ride
   verbatim.
4. **Per-connector locality.** `map_code` + outlier translation live in the
   provider module. Shared helpers (`vendor_error/5`, `passthrough:merge/4`,
   `merge_form/2`, json accessors, `sigv4:sign/1`, util encoders) are building
   blocks connectors call.
5. **Six codes**, byte-identical to the siblings. The raw `Retry-After` rides
   in `cause` under `<<"retryAfter">>`, parsed seconds under
   `<<"retryAfterSeconds">>`, the decoded body under `<<"raw">>`.
6. **Signing is hand-rolled, stateless, zero-dep.** SigV4 on `crypto`;
   FCM/APNs sign fresh per send unless a `token_cache` is supplied
   (`thinwrap_notifications_token_cache`).

## Erlang-specific choices

- **Synchronous calls** in the caller's process. The library starts no
  processes and keeps no state.
- **Maps everywhere**, atom keys for normalized data, binary keys for vendor
  JSON (`raw`, request bodies, `cause`). No records in the public API — they
  are awkward from Elixir and Gleam.
- **Token cache** is a map of two funs (`#{get := fun/1, set := fun/3}`), not
  a behaviour module: it closes over whatever store the caller has (ETS,
  persistent_term, a GenServer) without a module to write, and is trivial
  from Elixir.
- **Default transport** `thinwrap_notifications_httpc`: HTTPS only (a non-https
  URL is a typed `invalid_request`), 30 s timeout, never follows redirects,
  binary bodies, `User-Agent: thinwrap-notifications-erlang` (Cloudflare-fronted
  vendors 403 a missing/default UA), OTP's verified-TLS defaults.
- **BEAM floats are always finite**, and OTP's JSON decoder rejects
  `NaN`/`Infinity`/`1e999`, so the siblings' non-finite guards have no Erlang
  equivalent. The Python lone-surrogate encode failure maps to a binary that
  is not valid UTF-8 (`invalid_request`).
