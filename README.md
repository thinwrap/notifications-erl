# thinwrap_notifications (Erlang)

Unified, **SDK-free**, **zero-dependency** Erlang wrapper for sending **email,
SMS, push, and chat** across 35 providers. Switch vendor by changing the config's
`provider`; the input and output shapes stay identical. Synchronous, stateless,
OTP-only — bring your own HTTP client if you want `hackney`, `gun` or `Finch`.
Works the same from Elixir and Gleam.

```erlang
%% rebar.config
{deps, [thinwrap_notifications]}.
```

```elixir
# mix.exs
{:thinwrap_notifications, "~> 1.2"}
```

Requires Erlang/OTP ≥ 27. No runtime dependencies — AWS SigV4 (SES/SNS) and JWT
signing (FCM RS256, APNs ES256) use OTP `crypto` / `public_key`.

## Two-minute send

```erlang
Config = #{provider => sendgrid, api_key => <<"...">>, from => <<"hello@acme.com">>},
case thinwrap_notifications:send_email(Config, #{
    to => <<"user@example.com">>,
    subject => <<"Welcome">>,
    text => <<"Thanks for signing up!">>,
    html => <<"<p>Thanks for signing up!</p>">>
}) of
    {ok, #{status := Status, provider_message_id := Id}} ->
        io:format("~s ~s~n", [Status, Id]);
    {error, #{code := Code, message := Msg}} ->
        io:format("~s: ~ts~n", [Code, Msg])
end.
```

```elixir
{:ok, %{status: status}} =
  :thinwrap_notifications.send_sms(
    %{provider: :twilio, account_sid: sid, auth_token: token, from: "+15550001111"},
    %{to: "+15552223333", body: "hi"}
  )
```

## Channels & providers

The config's **`provider` selects the connector**. Sending on a channel the
provider doesn't serve raises `{badarg, _}` (e.g. `send_email/2` with `twilio`).
`thinwrap_notifications:supports(Provider, Channel)` and `providers(Channel)`
answer at runtime.

| Function | Providers |
|---|---|
| `send_email/2` | `ses`, `resend`, `mailgun`, `sendgrid`, `postmark`, `mailersend`, `mailtrap`, `brevo`, `sparkpost`, `scaleway` |
| `send_sms/2` | `vonage`, `twilio`, `plivo`, `sns`, `sinch`, `telnyx`, `infobip`, `messagebird`, `textmagic`, `d7networks` |
| `send_push/2` | `fcm`, `expo`, `apns`, `'one-signal'`, `'pusher-beams'`, `wonderpush` |
| `send_chat/2` | `telegram`, `slack`, `'whatsapp-business'`, `discord`, `'ms-teams'`, `'google-chat'`, `mattermost`, `'rocket-chat'`, `line` |

Config keys are the provider's credential and setting names (`api_key`,
`account_sid`, `webhook_url`, `from`, …). Any credential may be a binary or a
zero-arity fun returning one, which keeps the secret out of crash reports that
print the config. Per-provider details (endpoint, auth, config keys, error
mapping, passthrough keys) live in [`docs/providers/`](https://github.com/thinwrap/notifications-erl/tree/main/docs/providers).

## Switching providers

```erlang
%% Same send_email/2 call, same result — only the config changes.
Config = #{provider => resend, api_key => <<"...">>, from => <<"hi@acme.com">>}.
```

## The normalized surface

Every send returns `{ok, Result}`:

```erlang
#{success := boolean(),
  status := sent | queued | rejected | suppressed | unknown,
  provider_message_id := binary(),   % <<>> when the vendor returns none
  raw := term()}                     % decoded vendor body, verbatim
```

Only fields ≥90% of a channel's providers support are first-class on the input
(the **≥90% baseline-coverage rule**). Provider-specific fields flow through
`passthrough`:

```erlang
thinwrap_notifications:send_sms(Twilio, #{
    to => <<"+15552223333">>,
    body => <<"hi">>,
    passthrough => #{body => #{<<"mediaUrl">> => [<<"https://cdn/img.png">>]}}   % Twilio MMS
}).
```

`passthrough.body` is deep-merged into the request body, `headers`/`query`
shallow-merged; your values win on collision.

## Errors

An operation failure is `{error, Error}`, a plain map: a vendor error response,
a transport failure, or request data the connector rejects before sending (a
missing recipient, an invalid region, a header the vendor forbids, a header
value with a line break, a value that cannot be encoded) — the last group as
`invalid_request`, which is never worth retrying.

```erlang
#{code := invalid_recipient | rate_limited | auth_failed
        | provider_unavailable | invalid_request | unknown,
  message := binary(),
  status => integer(),            % absent for transport failures and pre-flight rejections
  provider_message => binary(),
  cause => #{<<"raw">> => VendorBody, <<"retryAfter">> => Header, <<"retryAfterSeconds">> => N}}
```

There is deliberately **no top-level retry key** — the raw `Retry-After` header
and its parsed seconds ride in `cause`. Retry is your policy.

Misusing the API raises `error({badarg, Description})` before any request: an
unknown or missing config/input key, a wrong type, a provider that doesn't serve
the channel. The description never includes config values.

## Bring your own transport

```erlang
Config = #{provider => sendgrid, api_key => Key, transport => {my_transport, Opts}}.
```

`my_transport` implements the one-callback `thinwrap_notifications_transport`
behaviour (`request/2`); a non-2xx must be returned as a response, never as an
error. The default, `thinwrap_notifications_httpc`, is OTP `httpc`: HTTPS-only,
30-second timeout, never follows redirects, verifies certificates with OTP's
defaults, and names itself in `User-Agent` (Cloudflare-fronted APIs reject a
missing one).

The wrapper is stateless: no caching, retries, telemetry, processes or ETS
tables. FCM/APNs sign a fresh token on every send unless you supply a token
cache on the config:

```erlang
token_cache => #{
    get => fun(Key) -> my_store:get(Key) end,              % {ok, {Token, ExpiresAtUnixSecs}} | error
    set => fun(Key, Token, ExpiresAt) -> my_store:put(Key, {Token, ExpiresAt}) end
}
```

For APNs the cache is **required in production**: Apple rejects a new provider
token more often than once per 20 minutes (`429 TooManyProviderTokenUpdates`).

## Relationship to the siblings

One of five thinwrap notifications libraries sharing a normalized surface and
byte-identical provider ids / error codes:

- TypeScript — [`@thinwrap/notifications`](https://github.com/thinwrap/notifications-ts)
- PHP — [`thinwrap/notifications`](https://github.com/thinwrap/notifications-php)
- Go — [`thinwrap/notifications-go`](https://github.com/thinwrap/notifications-go)
- Python — [`thinwrap-notifications`](https://github.com/thinwrap/notifications-py)
- Erlang — this package

## Security

Report vulnerabilities **privately** — please do not open a public issue.
Preferred: a [private security advisory](https://github.com/thinwrap/notifications-erl/security/advisories/new)
on this repository. Alternatively, email **security@thinwrap.dev**. Include the
affected versions and a minimal reproduction if you have one.

A vulnerability in a *provider's* own API or service belongs to that vendor
rather than to this wrapper — please report those upstream.

## License

MIT © Dmitry Polyanovsky & contributors
