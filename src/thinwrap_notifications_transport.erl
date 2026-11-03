-module(thinwrap_notifications_transport).
-moduledoc """
The bring-your-own HTTP seam.

The library never depends on a third-party HTTP client. It defines this one
callback and ships `thinwrap_notifications_httpc` (OTP `httpc`) as the default.
To use `hackney`, `gun`, `Finch`, … implement the behaviour and pass it in the
config:

```erlang
Config = #{provider => sendgrid, api_key => Key,
           transport => {my_hackney_transport, #{pool => mail}}}.
```

`request/2` sends one request and returns one response. Rules:

- A non-2xx answer is a **response**, never an error: return
  `{ok, #{status := 429, ...}}`. The connector owns status-to-error mapping,
  so a 429 still reads as `rate_limited`.
- Any `{error, Reason}` (connection refused, DNS, TLS, timeout) is reported as
  `provider_unavailable` with no `status`. Only the *kind* of the reason (its
  leading atom, e.g. `timeout` or `failed_connect`) is kept: a client's error
  term may embed the request URL, and for Telegram or a chat webhook the URL
  path IS the credential.
- `{error, {connector_error, Error}}` surfaces a ready-made
  `t:thinwrap_notifications:connector_error/0` unchanged (the default transport
  uses it to refuse non-`https` URLs).
- Never follow redirects: a 3xx must come back as a response, or the
  provider's credentials would be re-sent to wherever it points.
- Header values arrive as UTF-8 binaries whose code points are all ≤ 0xFF
  (the library rejects anything else first); send them as Latin-1, as
  `httpc` does with a character list.
""".

-export_type([request/0, response/0, headers/0, method/0, transport/0]).

-type method() :: get | post.
%% Header names as given by the connector (request) or lower-cased (response).
-type headers() :: #{binary() => binary()}.

-type request() :: #{
    method := method(),
    url := binary(),
    headers := headers(),
    body => binary()
}.

%% `headers` keys MUST be lower-cased; repeated headers joined with `", "`.
-type response() :: #{
    status := 100..599,
    headers := headers(),
    body := binary()
}.

-type transport() :: {module(), Opts :: term()}.

-callback request(Request :: request(), Opts :: term()) ->
    {ok, response()} | {error, term()}.
