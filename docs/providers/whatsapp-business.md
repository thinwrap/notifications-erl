# WhatsApp Business Connector (Erlang)

Chat via WhatsApp Business (Meta Cloud API) over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => 'whatsapp-business'`
to `thinwrap_notifications:send_chat/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => 'whatsapp-business',
    access_token => fun() -> env("META_WA_TOKEN") end,
    phone_number_id => env("META_WA_PHONE_NUMBER_ID")
    %% graph_api_version => <<"v21.0">>  (optional; defaults to v21.0)
},
{ok, #{status := sent, provider_message_id := Id}} =
    thinwrap_notifications:send_chat(Config, #{
        %% E.164 (no leading '+')
        to => <<"14155550100">>, body => <<"Hello from thinwrap">>
    }).
```

Passing a provider that does not serve chat to `send_chat/2` raises
`error({badarg, Description})`.

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `access_token` | `secret()` | yes | Meta Business Manager system-user token (Bearer credential) |
| `phone_number_id` | `binary()` | yes | Numeric phone-number ID — **not** the phone number itself |
| `graph_api_version` | `binary()` | no | Graph API version segment in the URL; absent or `<<>>` uses `v21.0` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

In Meta Business Manager → Business settings → System users, generate a
system-user token with WhatsApp Business permissions. Get `phone_number_id` from
WhatsApp Manager. Both are long-lived; sent as `Authorization: Bearer
<access_token>`. Static.

## Endpoint

`POST https://graph.facebook.com/<graph_api_version>/<phone_number_id>/messages`
(version defaults to `v21.0`).

## Narrowed input augmentations

`to` is **required** (recipient E.164 number); a missing `to` returns
`{error, #{code := invalid_request}}` before any HTTP call. The baseline body is
a text message: `{messaging_product: "whatsapp", recipient_type: "individual",
to: <to>, type: "text", text: {body: <body>}}`. On success `status` is `sent`
and `provider_message_id` comes from `messages[0].id`.

Keys in `passthrough.body` are sent **exactly as given**: write the Cloud API's
snake_case wire names (`recipient_type`, `biz_opaque_callback_data`, and nested
ones such as `preview_url`, `message_id`).
Expected keys for richer sends: `type` (overrides `"text"`), `template`,
`interactive`, `context` (`{message_id}`), media shapes
(`image`/`document`/`video`/…), and `text` (`{preview_url: true}`). WhatsApp
policy requires a `template` for any first contact or messages outside the 24h
customer-service window.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

The Cloud API returns most errors as HTTP 400, so a known error `code` decides
before the HTTP status
([error codes](https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes)):

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| (any) | `code` 0, 3, 10, 190, 200–299, 131005, 131031, 368 | `auth_failed` |
| (any) | `code` 4, 80007, 130429, 131048, 131056 | `rate_limited` |
| (any) | `code` 131026, 131021 | `invalid_recipient` |
| (any) | `code` 100, 131008, 131009, 131042, 131045, 131047 (24-hour window closed: send a template), 131051, 132000, 132001, 132012, 133010 (the business number is not registered) | `invalid_request` |
| (any) | `code` 1, 2, 131000, 131016, 131057 | `provider_unavailable` |
| 401, 403 | (other) | `auth_failed` |
| 429 | (other) | `rate_limited` |
| 5xx | (other) | `provider_unavailable` |
| 400 | (other) | `invalid_request` |
| (other) | — | `unknown` |

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the decoded body under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    to => <<"14155550100">>,
    body => <<"unused for template">>,
    passthrough => #{body => #{
        <<"type">> => <<"template">>,
        <<"template">> => #{
            <<"name">> => <<"hello_world">>,
            <<"language">> => #{<<"code">> => <<"en_US">>}
        }
    }}
}).
```

## Vendor docs

- API reference: https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages
- Templates: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-message-templates
- 24h window: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-messages
- Errors: https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes
