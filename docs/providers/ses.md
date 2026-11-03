# Amazon SES Connector (Erlang)

Email via the SES v2 HTTP API over direct HTTP (OTP only — no vendor SDK, no runtime dependencies). AWS Signature V4 is hand-rolled on OTP `crypto`.

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => ses` to
`thinwrap_notifications:send_email/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => ses,
    region => <<"us-east-1">>,
    access_key_id => env("AWS_ACCESS_KEY_ID"),
    secret_access_key => fun() -> env("AWS_SECRET_ACCESS_KEY") end,
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
| `region` | `binary()` | yes | AWS region (e.g. `us-east-1`); forms host `email.<region>.amazonaws.com` and the SigV4 credential scope. Validated as a single region label (as botocore does) before signing; anything else returns `{error, #{code := invalid_request}}`. No env inference. |
| `access_key_id` | `secret()` | yes | AWS access key id |
| `secret_access_key` | `secret()` | yes | AWS secret access key (SigV4 signing secret) |
| `session_token` | `secret()` | no | STS temporary-credential token; signed and sent as `X-Amz-Security-Token` |
| `from` | `binary()` | no | Default sender; a per-send `from` overrides it (one must be set) |
| `sender_name` | `binary()` | no | Display name composed as `Name <addr>`: quoted when it holds specials such as `,` or `.`, and RFC 2047 encoded-words (≤75 chars each) when non-ASCII, as SES requires for a Unicode "friendly from". A `from` already written as `Name <addr>` is parsed: its own name wins over `sender_name` and is encoded the same way, so angle brackets never nest. |
| `configuration_set_name` | `binary()` | no | Default config set on every send; per-send override via the passthrough body key `<<"ConfigurationSetName">>` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Create an IAM user/role with `ses:SendEmail`. Credentials are static (no
in-wrapper refresh); for temporary credentials, obtain them via STS elsewhere
and pass `session_token`. Every request is SigV4-signed for service `ses`.

## Endpoint

`POST https://email.<region>.amazonaws.com/v2/email/outbound-emails`

A `passthrough.query` is folded into both the request URL and the SigV4
canonical query so URL and signature agree.

## Narrowed input augmentations

`from` (+ `sender_name`) → `FromEmailAddress`; `to` → `Destination.ToAddresses`;
`cc`/`bcc` → `CcAddresses`/`BccAddresses`; `subject` → `Content.Simple.Subject`
(`{Data, Charset: "UTF-8"}`); `html`/`text` → `Content.Simple.Body.Html`/`.Text`;
`reply_to` → `ReplyToAddresses`. Every send uses `Content.Simple`:

- `attachments` → `Content.Simple.Attachments` (`{FileName, RawContent(base64),
  ContentType?, ContentDisposition}`); an attachment with `content_id` is sent as
  `ContentDisposition: "INLINE"` with `ContentId`, for `<img src="cid:…">`.
- `headers` → `Content.Simple.Headers` (`[{Name, Value}]`, sorted). SES limits
  these, so the connector returns `{error, #{code := invalid_request}}` before
  sending for: more than 15 headers; a name outside printable ASCII or with `:`;
  a line break in a name or value (rejected, never rewritten); an empty value;
  a value over 995 characters or name + value over 996; and the
  names SES sets itself (`BCC`, `CC`, `Content-Disposition`, `Content-Type`,
  `Date`, `From`, `Message-ID`, `MIME-Version`, `Reply-To`, `Return-Path`,
  `Subject`, `To` — use the typed field instead). A non-ASCII value is sent as
  RFC 2047 encoded-words, because SES accepts printable ASCII only.
- `tags` → `EmailTags` as `[{Name: tag, Value: tag}]`. SES allows only ASCII
  letters, digits, `_` and `-` (1–256 characters), so any other tag returns `{error, #{code := invalid_request}}` before sending. For distinct names and
  values, pass the passthrough body key `<<"EmailTags">>` instead.

`status` is `sent`; `provider_message_id` comes from the response
`MessageId`.

Keys ride in `passthrough.body` **exactly as given**, so write the SES v2
PascalCase names: `ConfigurationSetName` (per-send override),
`FromEmailAddressIdentityArn` (cross-account sending), `EmailTags`,
`FeedbackForwardingEmailAddress` (where bounces and complaints go — the v2
equivalent of v1's `ReturnPath`, which v2 does not have), and nested structures
such as `ListManagementOptions: {"ContactListName": …}`.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail.

The error code is read the way the AWS SDKs read restJson1 errors: the
`x-amzn-ErrorType` header, else body `code`/`Code`, else `__type`, cut at `,`
and `:` and taken after the last `#`. Most `SendEmail` exceptions share HTTP
400, so the code decides.

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 / 403 | (any) | `auth_failed` |
| 404 | (any) | `invalid_request` |
| 400 | `InvalidEmailAddress` | `invalid_recipient` |
| 400 | `SendingPausedException`, `AccountSuspendedException` (and the v1 names `AccountSendingPaused*`, `AccountSuspended`) | `auth_failed` |
| 400 | `Throttling(Exception)`, `TooManyRequestsException` | `rate_limited` |
| 400 | `MessageRejected` ("contains invalid content"), `MailFromDomainNotVerifiedException`, `LimitExceededException`, `BadRequestException`, or (other) | `invalid_request` |
| 429 / 454 | (any) | `rate_limited` |
| any | `Throttling(Exception)` | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
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
        <<"ConfigurationSetName">> => <<"marketing">>,
        <<"EmailTags">> => [#{<<"Name">> => <<"env">>, <<"Value">> => <<"prod">>}]
    }}
}).
```

## Vendor docs

- API reference: https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html
- Regional endpoints: https://docs.aws.amazon.com/general/latest/gr/ses.html
- AWS SigV4: https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
