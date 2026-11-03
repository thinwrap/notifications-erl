-module(thinwrap_notifications).
-moduledoc """
Send email, SMS, push and chat across 35 providers — one normalized surface,
zero dependencies.

Every function takes a provider **config** and an **input** map and returns
`{ok, Result}` or `{error, ConnectorError}`:

```erlang
Config = #{provider => sendgrid, api_key => <<"SG....">>, from => <<"hello@acme.com">>},
{ok, #{status := queued, provider_message_id := Id}} =
    thinwrap_notifications:send_email(Config, #{
        to => <<"user@example.com">>,
        subject => <<"Welcome">>,
        text => <<"Thanks for signing up!">>
    }).
```

The config's `provider` selects the vendor; switching vendor changes only the
config. Each provider serves exactly one channel (`supports/2`).

## Two kinds of failure

- **Send failures** — a vendor error response, a transport failure, or request
  data the connector rejects before sending (an invalid region, a header the
  vendor forbids, a header value with a line break, a value that cannot be
  encoded) — come back as `{error, connector_error()}`, a plain map whose
  `code` you branch on. `invalid_request` is never worth retrying.
- **Misuse** — a config or input that is not a map, a missing required config
  key, an unknown key, a value of the wrong type, a provider used on the wrong
  channel — raises `error({badarg, Description})`. Folding those into
  `{error, _}` would make a bug in the calling code look like bad end-user
  input or, worse, a retryable outage.

## The normalized surface

Every send returns `#{success := true, status := send_status(),
provider_message_id := binary(), raw := term()}`. `provider_message_id` is
`<<>>` when the vendor returned none; `raw` is the decoded vendor body (JSON
`null` is the atom `null`, also used for an empty or non-JSON body).

Only fields at least 90% of a channel's providers support are first-class on
the input (the baseline-coverage rule). Provider-specific fields flow through
`passthrough`; provider-level settings live on the config.

## Passthrough

Every input accepts `passthrough => #{body => map(), headers => map(),
query => map()}`, forwarded as given and overriding what the connector set
(auth included): `body` deep-merged, `headers` and `query` shallow-merged,
header names case-insensitively. Write the vendor's own wire names. Seven
connectors rewrite only the TOP-LEVEL `body` keys to the vendor's casing:
Postmark and Twilio to PascalCase, Mailtrap, SparkPost, SendGrid, MailerSend
and Scaleway to snake_case; nested maps always ride verbatim.

## Errors

`connector_error()` carries `code` (one of the six canonical codes shared with
the sibling libraries), `message`, and when known `status`,
`provider_message` and `cause`. For a vendor error `cause` is
`#{<<"raw">> => DecodedBody}` plus `<<"retryAfter">>` (the raw header) and
`<<"retryAfterSeconds">>` when the vendor sent `Retry-After`. There is
deliberately no top-level retry field: retry is the caller's policy.
""".

-export([send_email/2, send_sms/2, send_push/2, send_chat/2, supports/2, providers/1]).

-export_type([
    config/0,
    provider/0,
    channel/0,
    secret/0,
    token_cache/0,
    send_status/0,
    connector_error/0,
    passthrough/0,
    email_input/0,
    email_attachment/0,
    sms_input/0,
    push_input/0,
    chat_input/0,
    send_result/0,
    result/0
]).

-type channel() :: email | sms | push | chat.

-doc """
Provider ids, byte-identical to the sibling libraries' values (hence the
quoted atoms such as `'one-signal'`).
""".
-type provider() ::
    %% Email
    ses
    | resend
    | mailgun
    | sendgrid
    | postmark
    | mailersend
    | mailtrap
    | brevo
    | sparkpost
    | scaleway
    %% SMS
    | vonage
    | twilio
    | plivo
    | sns
    | sinch
    | telnyx
    | infobip
    | messagebird
    | textmagic
    | d7networks
    %% Push
    | fcm
    | expo
    | apns
    | 'one-signal'
    | 'pusher-beams'
    | wonderpush
    %% Chat
    | telegram
    | slack
    | 'whatsapp-business'
    | discord
    | 'ms-teams'
    | 'google-chat'
    | mattermost
    | 'rocket-chat'
    | line.

-doc """
A credential, or a zero-arity fun returning it. The fun form keeps the secret
out of crash reports and logs that print the config map (EEF secure-coding
guidance).
""".
-type secret() :: binary() | fun(() -> binary()).

-doc """
A bring-your-own cache for the FCM and APNs auth tokens. The library holds no
token state: without a cache it signs a fresh token on every send. `get(Key)`
returns `{ok, {Token, ExpiresAt}}` or `error`; `set(Key, Token, ExpiresAt)` is
called after a fresh token is minted (its return value is ignored).
`ExpiresAt` is an absolute Unix time in seconds. Nothing is evicted on a
vendor 401/403 — eviction is the cache's policy. For APNs a cache is required
in production: Apple rejects a new provider token more often than once per
20 minutes (`429 TooManyProviderTokenUpdates`).

```erlang
Cache = #{
    get => fun(Key) -> case ets:lookup(tokens, Key) of
                           [{_, Tok, Exp}] -> {ok, {Tok, Exp}};
                           [] -> error
                       end end,
    set => fun(Key, Tok, Exp) -> ets:insert(tokens, {Key, Tok, Exp}) end
}.
```
""".
-type token_cache() :: #{
    get := fun((Key :: binary()) -> {ok, {Token :: binary(), ExpiresAt :: number()}} | error),
    set := fun((Key :: binary(), Token :: binary(), ExpiresAt :: number()) -> term())
}.

-doc """
Provider configuration. `provider` selects the connector; the other keys
depend on it (credentials are `t:secret/0`, everything else a binary; keys
not listed as required are optional):

- `ses`: requires `region`, `access_key_id`, `secret_access_key`; optional
  `session_token`, `from`, `sender_name`, `configuration_set_name`.
- `resend`, `sendgrid`, `brevo`: requires `api_key`; optional `from`,
  `sender_name`.
- `mailgun`: requires `api_key`, `domain`; optional `from`, `sender_name`,
  `region` (`<<"eu">>`), `username`, `base_url`.
- `postmark`: requires `server_token`; optional `from`, `sender_name`,
  `message_stream`.
- `mailersend`: requires `api_token`; optional `from`, `sender_name`.
- `mailtrap`: requires `api_token`; optional `mode` (`<<"sandbox">>` /
  `<<"production">>`), `inbox_id`, `from`, `sender_name`.
- `sparkpost`: requires `api_key`; optional `from`, `sender_name`, `region`
  (`<<"eu">>`).
- `scaleway`: requires `secret_key`, `project_id`; optional `from`,
  `sender_name`, `region` (default `<<"fr-par">>`).
- `vonage`: requires `api_key`, `api_secret`; optional `from`.
- `twilio`: requires `account_sid`, `auth_token`; optional `from`, `region`,
  `edge`.
- `plivo`: requires `auth_id`, `auth_token`; optional `from`.
- `sns`: requires `region`, `access_key_id`, `secret_access_key`; optional
  `session_token`.
- `sinch`: requires `service_plan_id`, `api_token`; optional `from`, `region`.
- `telnyx`, `messagebird`, `d7networks`: requires `api_key` / `access_key` /
  `api_token`; optional `from`.
- `infobip`: requires `base_url`, `api_key`; optional `from`.
- `textmagic`: requires `username`, `api_key`; optional `from`.
- `fcm`: requires `project_id`, `client_email`, `private_key`; optional
  `token_cache`.
- `expo`: no required keys; optional `access_token`.
- `apns`: requires `team_id`, `key_id`, `private_key`, `bundle_id`; optional
  `env`, `token_cache`.
- `'one-signal'`: requires `app_id`, `api_key`.
- `'pusher-beams'`: requires `instance_id`, `secret_key`.
- `wonderpush`: requires `access_token`; optional `application_id`.
- `telegram`: requires `bot_token`.
- `slack`, `discord`, `'ms-teams'`, `'google-chat'`, `mattermost`,
  `'rocket-chat'`: requires `webhook_url`.
- `'whatsapp-business'`: requires `access_token`, `phone_number_id`; optional
  `graph_api_version`.
- `line`: requires `channel_access_token`.

`from` is the default sender; an input `from` overrides it. A chat webhook URL
embeds its token, so it is a credential. Optional on every provider:
`transport` (see `thinwrap_notifications_transport`; default
`{thinwrap_notifications_httpc, #{}}`).
""".
-type config() :: #{
    provider := provider(),
    transport => thinwrap_notifications_transport:transport(),
    token_cache => token_cache(),
    atom() => secret() | binary()
}.

-doc "Normalized delivery status on every result.".
-type send_status() :: sent | queued | rejected | suppressed | unknown.

-doc """
The send-failure value. `code` is the normalized classification shared with
the sibling libraries; `status` is the HTTP status when the provider answered
(absent for a transport failure or a pre-flight rejection); `cause` is
`#{<<"raw">> => DecodedVendorBody}` (+ `<<"retryAfter">>`,
`<<"retryAfterSeconds">>`), or for a transport or encoding failure only its
kind, `#{<<"raw">> => #{<<"exception">> => Kind}}` — never the request.
""".
-type connector_error() :: #{
    code := thinwrap_notifications_error:code(),
    message := binary(),
    status => integer(),
    provider_message => binary(),
    cause => term()
}.

-type passthrough() :: #{
    body => #{atom() | binary() => term()},
    headers => #{atom() | binary() => binary() | number() | boolean()},
    query => #{atom() | binary() => binary() | number() | atom()}
}.

-doc """
An attachment. `content` is the raw bytes (the connector base64-encodes as the
vendor needs). With `content_id` set the attachment is inline, referenced as
`cid:<content_id>` from the HTML.
""".
-type email_attachment() :: #{
    filename := binary(),
    content := binary(),
    content_type => binary(),
    content_id => binary()
}.

-doc """
The ≥90%-baseline email payload. Every key is optional (empty by default, as
in the siblings); `from` overrides the config's default sender. Header names
and values are binaries.
""".
-type email_input() :: #{
    to => binary(),
    subject => binary(),
    from => binary(),
    cc => [binary()],
    bcc => [binary()],
    reply_to => binary(),
    text => binary(),
    html => binary(),
    attachments => [email_attachment()],
    headers => #{binary() => binary()},
    tags => [binary()],
    passthrough => passthrough()
}.

-doc "The ≥90%-baseline SMS payload; `from` overrides the config's sender.".
-type sms_input() :: #{
    to => binary(),
    body => binary(),
    from => binary(),
    passthrough => passthrough()
}.

-doc """
The four-field push baseline. `to` is a single device token / recipient;
topic and multi-target delivery, badge, sound, TTL and platform blocks flow
through `passthrough`.
""".
-type push_input() :: #{
    to => binary(),
    title => binary(),
    body => binary(),
    data => #{binary() => binary()},
    passthrough => passthrough()
}.

-doc """
The chat baseline. `to` is the channel / room / recipient (unused by
webhook-bound connectors, whose URL encodes the target). Rich content
(blocks, attachments, threads) flows through `passthrough`.
""".
-type chat_input() :: #{
    body => binary(),
    to => binary(),
    passthrough => passthrough()
}.

-type send_result() :: #{
    success := true,
    status := send_status(),
    provider_message_id := binary(),
    raw := term()
}.

-doc "What every `send_*` function returns.".
-type result() :: {ok, send_result()} | {error, connector_error()}.

-doc "Whether `Provider` serves `Channel`.".
-spec supports(provider(), channel()) -> boolean().
supports(Provider, Channel) ->
    thinwrap_notifications_input:channel_of(Provider) =:= Channel.

-doc "The providers serving `Channel`, sorted.".
-spec providers(channel()) -> [provider()].
providers(Channel) ->
    [P || P <- thinwrap_notifications_input:providers(), supports(P, Channel)].

-doc """
Send an email (SES, Resend, Mailgun, SendGrid, Postmark, MailerSend,
Mailtrap, Brevo, SparkPost, Scaleway).
""".
-spec send_email(config(), email_input()) -> result().
send_email(Config, Input) -> call(email, Config, Input).

-doc """
Send an SMS (Vonage, Twilio, Plivo, SNS, Sinch, Telnyx, Infobip, MessageBird,
TextMagic, D7 Networks).
""".
-spec send_sms(config(), sms_input()) -> result().
send_sms(Config, Input) -> call(sms, Config, Input).

-doc "Send a push notification (FCM, Expo, APNs, OneSignal, Pusher Beams, WonderPush).".
-spec send_push(config(), push_input()) -> result().
send_push(Config, Input) -> call(push, Config, Input).

-doc """
Send a chat message (Telegram, Slack, WhatsApp Business, Discord, MS Teams,
Google Chat, Mattermost, Rocket.Chat, LINE).
""".
-spec send_chat(config(), chat_input()) -> result().
send_chat(Config, Input) -> call(chat, Config, Input).

call(Channel, Config0, Input0) ->
    Config = thinwrap_notifications_input:config(Channel, Config0),
    Input = thinwrap_notifications_input:input(Channel, Input0),
    #{provider := Provider} = Config,
    Mod = provider_module(Provider),
    %% Provider modules land channel by channel; until a module exists its
    %% provider is validated but cannot send.
    case code:ensure_loaded(Mod) of
        {module, Mod} -> ok;
        _ -> erlang:error({provider_not_available, Provider})
    end,
    try Mod:send(Config, Input) of
        Result -> {ok, Result}
    catch
        throw:{thinwrap_notifications_error, Error} -> {error, Error}
    end.

%% One module per provider, named after the Python sibling's `_<provider>.py`.
provider_module(ses) -> thinwrap_notifications_ses;
provider_module(resend) -> thinwrap_notifications_resend;
provider_module(mailgun) -> thinwrap_notifications_mailgun;
provider_module(sendgrid) -> thinwrap_notifications_sendgrid;
provider_module(postmark) -> thinwrap_notifications_postmark;
provider_module(mailersend) -> thinwrap_notifications_mailersend;
provider_module(mailtrap) -> thinwrap_notifications_mailtrap;
provider_module(brevo) -> thinwrap_notifications_brevo;
provider_module(sparkpost) -> thinwrap_notifications_sparkpost;
provider_module(scaleway) -> thinwrap_notifications_scaleway;
provider_module(vonage) -> thinwrap_notifications_vonage;
provider_module(twilio) -> thinwrap_notifications_twilio;
provider_module(plivo) -> thinwrap_notifications_plivo;
provider_module(sns) -> thinwrap_notifications_sns;
provider_module(sinch) -> thinwrap_notifications_sinch;
provider_module(telnyx) -> thinwrap_notifications_telnyx;
provider_module(infobip) -> thinwrap_notifications_infobip;
provider_module(messagebird) -> thinwrap_notifications_messagebird;
provider_module(textmagic) -> thinwrap_notifications_textmagic;
provider_module(d7networks) -> thinwrap_notifications_d7networks;
provider_module(fcm) -> thinwrap_notifications_fcm;
provider_module(expo) -> thinwrap_notifications_expo;
provider_module(apns) -> thinwrap_notifications_apns;
provider_module('one-signal') -> thinwrap_notifications_onesignal;
provider_module('pusher-beams') -> thinwrap_notifications_pusherbeams;
provider_module(wonderpush) -> thinwrap_notifications_wonderpush;
provider_module(telegram) -> thinwrap_notifications_telegram;
provider_module(slack) -> thinwrap_notifications_slack;
provider_module('whatsapp-business') -> thinwrap_notifications_whatsappbusiness;
provider_module(discord) -> thinwrap_notifications_discord;
provider_module('ms-teams') -> thinwrap_notifications_msteams;
provider_module('google-chat') -> thinwrap_notifications_googlechat;
provider_module(mattermost) -> thinwrap_notifications_mattermost;
provider_module('rocket-chat') -> thinwrap_notifications_rocketchat;
provider_module(line) -> thinwrap_notifications_line.
