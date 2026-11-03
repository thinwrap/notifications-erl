# Conventions — `thinwrap_notifications` (Erlang)

## Files and names

- Every module is prefixed `thinwrap_notifications_` (Erlang has one global
  module namespace). Provider modules: `thinwrap_notifications_<provider>.erl`,
  the Python module name without its underscore (`_whatsappbusiness.py` →
  `thinwrap_notifications_whatsappbusiness`).
- Provider ids are atoms byte-identical to the sibling values, so the hyphenated
  ones are quoted: `'one-signal'`, `'pusher-beams'`, `'whatsapp-business'`,
  `'ms-teams'`, `'google-chat'`, `'rocket-chat'`.
- Internal modules carry `-moduledoc false.`; internal exported functions
  carry `-doc false.`. Every exported function has a `-spec`
  (`warn_missing_spec` is on, `warnings_as_errors` too).
- Formatting is erlfmt (`rebar3 fmt`); CI runs `rebar3 fmt --check`.
- Style is Elvis (`rebar3 lint`, policy in `elvis.config`, each deviation
  commented there); dead code is rebar3_hank (`rebar3 hank`); types beyond
  Dialyzer are eqWAlizer over `src/` (`scripts/eqwalize.sh`: needs Java 11+
  on `PATH` and ELP, `brew install erlang-language-platform`). All three are
  CI gates. Call other modules by their literal name, never through a
  module-alias macro (`?ERR:fail/1`): Elvis reads unexpanded source and flags
  every such call as dynamic. No `-import`, `if`, or `begin ... end` in `src/`.
- Comments explain WHY (vendor quirks, live-verified behaviour, billing), not
  the history of the change.

## Data shapes

| Thing | Shape |
|---|---|
| config | map, `provider => atom()` + that provider's keys (snake_case atoms named after the Python config fields; `from_` is `from`) |
| credentials | `binary()` or `fun(() -> binary())`, read with `thinwrap_notifications_input:secret/2` at the point of use |
| other config values | binaries, read with `thinwrap_notifications_util:cfg/2` (absent → `<<>>`, the Python default) |
| input | map, atom keys; every key optional and filled with the Python default by the input module, so connectors read with `maps:get/2` / `:=` |
| strings | binaries, UTF-8 |
| closed vocabularies | atoms, byte-identical to the sibling string values (`queued`, `invalid_recipient`) |
| result | `#{success := true, status, provider_message_id := binary(), raw}` — build with `thinwrap_notifications_util:result/3` |
| absent optional output | key **omitted** — never `undefined`/`null`/`nil` |
| vendor JSON (request bodies, `raw`, `cause`) | maps with **binary** keys; decoded JSON `null` (and an empty/non-JSON body) is the atom `null` |
| query strings | ordered `[{binary(), binary()}]` |
| form bodies | ordered `[{binary(), term()}]`; list value = repeated field, map = JSON, `null` skipped |
| headers in requests | `#{binary() => binary()}`; a map has no order, so list-shaped vendor headers (`[{Name, Value}]`) are built in sorted name order |

Request bodies use binary keys so a caller's `passthrough.body` (keys
converted to binaries) deep-merges onto them. Build optional body fields with
`thinwrap_notifications_util:put_nonempty/3` (the Python `if msg.field:`).

## Two kinds of failure

- **Send failure** → `{error, connector_error()}`: vendor error, transport
  failure, request *data* the vendor would reject (`invalid_request`: a bad
  region, a forbidden header, an empty mode, an unencodable value). Inside a
  connector: `thinwrap_notifications_error:fail(thinwrap_notifications_error:invalid_request(Msg))`,
  `vendor_error(Status, RespHeaders, Raw, Code, Msg)` for a vendor response, or
  `new(Code, Fields)` for anything else.
- **Misuse** → `erlang:error({badarg, Description})`, raised by
  `thinwrap_notifications_input` before any HTTP: config/input not a map,
  unknown or missing required keys, wrong value types, provider on the wrong
  channel. Descriptions never include config values (they may be
  credentials), and no public function may fail with a `function_clause` on
  the config (its args would be printed).

Where the Python sibling raises `ConnectorError`, Erlang returns `{error, _}`;
where it raises `TypeError`/`ValueError`, Erlang raises `badarg`. A Python
connector-level check that only exists because Python does not type-check its
dataclasses (e.g. SES "header names and values must be strings") is covered by
input validation here and becomes `badarg`.

## Error mapping

Each provider module has a private `map_code(Status, ...)` porting the
sibling truth table. Baseline, overridden where the vendor gives finer signal:

| HTTP | code |
|---|---|
| 400 / 404 / 422 | `invalid_request` |
| 401 / 403 | `auth_failed` |
| 429 | `rate_limited` |
| 5xx | `provider_unavailable` |
| transport | `provider_unavailable` (no `status`) |
| unparseable / unexpected | `unknown` |

`vendor_error/5` adds the `Retry-After` surfacing and the
`<<"<no vendor message>">>` placeholder; never build a vendor error by hand.

## Credentials

Read them with `thinwrap_notifications_input:secret(Config, Key)` at the point
of use. Never put a credential (or a URL that embeds one) in an error message
or cause.

## Testing

- eunit, one `test/thinwrap_notifications_<provider>_tests.erl` per Python
  test file, plus the provider's cases from the cross-cutting files
  (`core_tests`, `passthrough_casing_tests`, `request_guards_tests`).
- `thinwrap_notifications_fake_transport:config(Config, Responses)` returns
  `{Config1, Pid}`: queued responses (`resp/2,3` — header names are
  lower-cased like a real transport — or `{error, Reason}`), recorded requests
  via `calls/1` / `last/1`, helpers `qget/2`, `path_of/1`, `host_of/1`,
  `body_json/1`, `body_form/1` (multi-value), `body_form_single/1`,
  `header/2` (case-insensitive), `header_names/1`.
- Assert the captured request (URL, headers, body), the normalized result,
  and the error `code`/`status`; assert `?F:calls(P) =:= []` for pre-flight
  rejections.
- Never put real-looking keys in tests (secret scanners flag even the AWS example
  keys): use `<<"k">>`, `<<"TESTKEYID">>`, `<<"test-secret">>`.
- `thinwrap_notifications_httpc_tests` exercises the real adapter against a
  local TLS listener (P-256 test certs: OTP's default test keys cannot be
  served to a TLS 1.3 client); no test touches the network.
