# Amazon SNS Connector (Erlang)

Amazon SNS SMS via direct HTTP with hand-rolled AWS Signature V4 (OTP
`crypto` only — no AWS SDK, no runtime dependencies).

## Quick install

See the [package README](../../README.md) for installation. The config's
`provider` key selects the connector — pass `provider => sns` to
`thinwrap_notifications:send_sms/2`. Credentials may be a binary or a
zero-arity fun returning one (the fun keeps the secret out of crash reports
that print the config):

```erlang
env(Name) -> list_to_binary(os:getenv(Name)).

Config = #{
    provider => sns,
    region => <<"us-east-1">>,
    access_key_id => fun() -> env("AWS_ACCESS_KEY_ID") end,
    secret_access_key => fun() -> env("AWS_SECRET_ACCESS_KEY") end
},
{ok, #{status := sent, provider_message_id := Id, raw := Xml}} =
    thinwrap_notifications:send_sms(Config, #{to => <<"+15551234567">>, body => <<"Hi">>}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `region` | `binary()` | yes | SMS-eligible AWS region (e.g. `<<"us-east-1">>`); no environment inference. It forms the host, so it is validated as a single region label (as botocore does) and anything else returns `{error, #{code := invalid_request}}` before signing |
| `access_key_id` | `secret()` | yes | AWS access key id (SigV4 credential) |
| `secret_access_key` | `secret()` | yes | AWS secret access key (SigV4 signing secret) |
| `session_token` | `secret()` | no | STS temporary session token; when set it is signed and sent as `X-Amz-Security-Token` |

Inject a custom transport with the config's `transport` key
(`transport => {MyTransport, Opts}`, see `thinwrap_notifications_transport`);
the default `thinwrap_notifications_httpc` is HTTPS-only and never follows
redirects.

## Auth setup

Requests are signed with **AWS Signature V4** (`thinwrap_notifications_sigv4`,
on `crypto`). The merged form body is serialized once — those exact bytes are
both the signed payload hash and the transmitted body. Any `passthrough.query`
is folded (sorted, RFC 3986-encoded) identically into both the signed canonical
query and the request URL, or the signature would not match. `Content-Type`
and any other passthrough headers are signed; the SigV4 headers
(`Host`/`X-Amz-Date`/`X-Amz-Content-Sha256`/`Authorization`) are not
caller-overridable.

## Endpoint

`POST https://sns.<region>.amazonaws.com/` — AWS Query API
(`Action=Publish`, `Version=2010-03-31`), `application/x-www-form-urlencoded`.

## Narrowed input augmentations

`to` (phone, E.164) → `PhoneNumber`; `body` → `Message`. Either `to` or a
`TopicArn` passthrough is required (else `{error, #{code := invalid_request}}`,
no request sent). The response is **XML**: on success `status` is `sent`,
`provider_message_id` is the `<MessageId>` tag, and `raw` is the response body
as a binary (not decoded).

Keys ride in `passthrough.body` using the AWS Query keys **verbatim** (no
casing transform — the indexed-attribute keys are not simple-case
transformable): `TopicArn`, `MessageStructure`, and
`MessageAttributes.entry.N.{Name,Value.DataType,Value.StringValue,Value.BinaryValue}`
— including the `AWS.SNS.SMS.{SMSType,SenderID,MaxPrice}` attributes.

## Error mapping

Failures return `{error, ConnectorError}`; branch on its `code`, with
`status` and `cause` for detail. The HTTP status is checked first, then the XML
`<Code>` disambiguates within 4xx:

| Vendor signal | `code` |
|---|---|
| `<Code>` InvalidClientTokenId / SignatureDoesNotMatch, or HTTP 401/403 | `auth_failed` |
| `<Code>` Throttling / ThrottlingException, or HTTP 429 | `rate_limited` |
| HTTP 5xx | `provider_unavailable` |
| `<Code>` InvalidParameter / InvalidParameterValue, or other HTTP ≥400 | `invalid_request` |
| (otherwise) | `unknown` |

The message is the XML `<Message>`; `cause`'s `<<"raw">>` holds the raw XML.
When the vendor sends `Retry-After`, `cause` also carries the raw header under
`<<"retryAfter">>` and its parsed seconds under `<<"retryAfterSeconds">>`.

## Passthrough examples

```erlang
{ok, _} = thinwrap_notifications:send_sms(Config, #{
    to => <<"+15551234567">>,
    body => <<"Hi">>,
    passthrough => #{
        body => #{
            <<"MessageAttributes.entry.1.Name">> => <<"AWS.SNS.SMS.SMSType">>,
            <<"MessageAttributes.entry.1.Value.DataType">> => <<"String">>,
            <<"MessageAttributes.entry.1.Value.StringValue">> => <<"Transactional">>
        }
    }
}).
```

## Vendor docs

- API reference: https://docs.aws.amazon.com/sns/latest/api/API_Publish.html
- SMS attributes: https://docs.aws.amazon.com/sns/latest/dg/sms_sending-overview.html#sms_publish-to-phone
- Regional availability: https://docs.aws.amazon.com/sns/latest/dg/sns-supported-regions-countries.html
