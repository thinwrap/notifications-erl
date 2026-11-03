# Microsoft Teams Connector (Erlang)

Chat via Microsoft Teams Workflows webhooks (and legacy Office 365 Incoming Webhooks) over direct HTTP (OTP only — no vendor SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => 'ms-teams'` to
`thinwrap_notifications:send_chat/2`. The webhook URL embeds its token, so it
is a credential: it may be a binary or a zero-arity fun returning one (the fun
keeps the secret out of crash reports that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => 'ms-teams',
    %% https://prod-00.westus.logic.azure.com:443/workflows/.../triggers/manual/paths/invoke?...
    webhook_url => fun() -> env("TEAMS_WEBHOOK_URL") end
},
{ok, #{status := sent}} =
    thinwrap_notifications:send_chat(Config, #{
        %% `to` is ignored — the webhook fixes the channel
        body => <<"Build passed">>
    }).
```

Passing a provider that does not serve chat to `send_chat/2` raises
`error({badarg, Description})`.

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `webhook_url` | `secret()` | yes | Teams Workflows webhook URL (or a legacy Incoming Webhook URL) — **the URL itself is the credential** |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create a webhook with Workflows (a flow whose trigger is *When a Teams webhook
request is received*) and copy the generated URL. Microsoft 365 Connectors
(Incoming Webhook URLs on `*.webhook.office.com` / `outlook.office.com`) are
being deprecated but are still accepted. The URL is the credential. This is
webhook-URL-as-auth, so the input's `to` is unused (each webhook is pinned to
a channel).

The URL must be `https://`: any other scheme returns `{error, #{code :=
invalid_request}}` before sending, whatever the transport, so the token never
travels in cleartext. Errors never echo the URL.

## Endpoint

`POST <webhook_url>` — the configured webhook URL is the endpoint.

## Narrowed input augmentations

`to` is **ignored** (the webhook targets the channel). `body` is synthesized
into an Adaptive Card v1.4 with a single `TextBlock`, wrapped in the required
Teams envelope: `{type: "message", attachments: [{contentType:
"application/vnd.microsoft.card.adaptive", content: <card>}]}`. On success
`status` is `sent`. Neither webhook kind returns a message id, so
`provider_message_id` is **always `<<>>`** and `raw` is the response text as a
binary (e.g. `<<"1">>` or `<<>>`).

Success detection:

- **202** — success regardless of body (a Workflows trigger without a Response
  action answers `202 Accepted`).
- **Other 2xx** whose body embeds `HTTP error NNN` — failure with status `NNN`
  (a legacy connector reports throttling and delivery failures inside a 200).
- **Other 2xx** from a legacy connector host (`*.webhook.office.com`,
  `outlook.office.com`) whose body is not the literal `1` — failure (status 502,
  `provider_unavailable`).
- **Other 2xx** otherwise — success.

`passthrough.body` is **forwarded verbatim (no casing transform)**. To send a
full custom Adaptive Card (or a legacy MessageCard), supply `attachments` via
`passthrough.body` — the list replaces the synthesized value on merge.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail (`cause`'s `<<"raw">>` is the response text).

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 400 | body contains `invalid webhook` | `auth_failed` |
| 401, 403, 404 | (webhook removed) | `auth_failed` |
| 429 | (any) | `rate_limited` |
| 400 | (other — malformed card) | `invalid_request` |
| 5xx | (any) | `provider_unavailable` |
| (other) | — | `unknown` |

Teams quirk: revoked / malformed webhook URLs return HTTP 400 with a plain-text
body containing `Invalid webhook URL` (not 404), special-cased to `auth_failed`.

When the vendor sends `Retry-After` (typically on 429), the error's `cause`
carries the raw header under `<<"retryAfter">>` and its parsed seconds under
`<<"retryAfterSeconds">>`, next to the response text under `<<"raw">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_chat(Config, #{
    body => <<"unused when attachments supplied">>,
    passthrough => #{body => #{
        <<"type">> => <<"message">>,
        <<"attachments">> => [#{
            <<"contentType">> => <<"application/vnd.microsoft.card.adaptive">>,
            <<"content">> => #{
                <<"type">> => <<"AdaptiveCard">>,
                <<"version">> => <<"1.4">>,
                <<"body">> => [#{
                    <<"type">> => <<"TextBlock">>,
                    <<"text">> => <<"Build passed">>,
                    <<"weight">> => <<"Bolder">>
                }]
            }
        }]
    }}
}).
```

## Vendor docs

- API reference: https://learn.microsoft.com/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook
- Workflows request trigger (202 Accepted): https://learn.microsoft.com/azure/connectors/connectors-native-reqres
- Adaptive Cards: https://adaptivecards.io/explorer/
