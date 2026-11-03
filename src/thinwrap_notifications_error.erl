-module(thinwrap_notifications_error).
-moduledoc """
Builders for `t:thinwrap_notifications:connector_error/0`, the plain map every
send failure is returned as.

Connectors build errors here and `fail/1` them; the public
`thinwrap_notifications` functions catch that and return `{error, Error}`.
Misuse of the API (a missing config key, a provider on the wrong channel) is
not a connector error: it raises `badarg`.

There is deliberately no `retry_after_seconds` key: for a vendor HTTP error the
raw `Retry-After` header rides in `cause` as `<<"retryAfter">>` and its parsed
seconds as `<<"retryAfterSeconds">>`, next to the decoded body under
`<<"raw">>` — the `{raw, retryAfter?, retryAfterSeconds?}` cause shape shared
with the sibling libraries.
""".

-export([
    new/2,
    invalid_request/1,
    vendor_error/5,
    parse_retry_after/1,
    parse_retry_after/2,
    assert_webhook_https/2,
    fail/1,
    codes/0
]).

-export_type([code/0]).

%% The six canonical values, byte-identical across the thinwrap notifications
%% siblings (TypeScript, PHP, Go, Python).
-type code() ::
    invalid_recipient
    | rate_limited
    | auth_failed
    | provider_unavailable
    | invalid_request
    | unknown.

-define(THROW_TAG, thinwrap_notifications_error).

-doc "Every `code()` value, in declaration order.".
-spec codes() -> [code()].
codes() ->
    [invalid_recipient, rate_limited, auth_failed, provider_unavailable, invalid_request, unknown].

-doc """
Build an error. `Fields` may carry `status`, `provider_message`, `message`
and `cause`; `message` falls back to `provider_message`, then to
`<<"Connector error">>`, so it is always present. `undefined` values are
dropped: an absent optional key is omitted, never `undefined`.
""".
-spec new(code(), map()) -> thinwrap_notifications:connector_error().
new(Code, Fields) ->
    Message =
        case Fields of
            #{message := M} when is_binary(M), M =/= <<>> -> M;
            #{provider_message := P} when is_binary(P), P =/= <<>> -> P;
            _ -> <<"Connector error">>
        end,
    Base = #{code => Code, message => Message},
    Kept = maps:filter(fun(_K, V) -> V =/= undefined end, Fields),
    maps:merge(Base, maps:with([status, provider_message, cause], Kept)).

-doc "A pre-flight `invalid_request` (no HTTP round-trip).".
-spec invalid_request(binary()) -> thinwrap_notifications:connector_error().
invalid_request(Msg) ->
    new(invalid_request, #{message => Msg, provider_message => Msg}).

-doc """
The error for a non-2xx response (or a 2xx the connector re-classifies). The
vendor-to-code classification and the message are the connector's; this adds
the shared `Retry-After` surfacing. An empty message becomes
`<<"<no vendor message>">>`.
""".
-spec vendor_error(
    integer(), thinwrap_notifications_transport:headers(), term(), code(), binary() | undefined
) -> thinwrap_notifications:connector_error().
vendor_error(Status, Headers, Raw, Code, ProviderMsg) ->
    Cause0 = #{<<"raw">> => Raw},
    Cause =
        case maps:get(<<"retry-after">>, Headers, <<>>) of
            <<>> ->
                Cause0;
            RetryAfter ->
                C1 = Cause0#{<<"retryAfter">> => RetryAfter},
                case parse_retry_after(RetryAfter) of
                    undefined -> C1;
                    Secs -> C1#{<<"retryAfterSeconds">> => Secs}
                end
        end,
    Msg =
        case ProviderMsg of
            undefined -> <<"<no vendor message>">>;
            <<>> -> <<"<no vendor message>">>;
            _ -> ProviderMsg
        end,
    new(Code, #{status => Status, provider_message => Msg, message => Msg, cause => Cause}).

-doc """
Parse a `Retry-After` header: a non-negative count of seconds, or an
HTTP-date (seconds from now, floored at 0). `undefined` when unparseable or
negative.
""".
-spec parse_retry_after(binary()) -> non_neg_integer() | undefined.
parse_retry_after(Value) ->
    parse_retry_after(Value, erlang:system_time(second)).

-doc false.
%% `parse_retry_after/1` against an explicit "now" (Unix seconds), so the
%% HTTP-date branch is testable.
-spec parse_retry_after(binary(), integer()) -> non_neg_integer() | undefined.
parse_retry_after(Value, Now) ->
    S = string:trim(Value),
    case S of
        <<>> ->
            undefined;
        _ ->
            try binary_to_integer(S) of
                N when N >= 0 -> N;
                _ -> undefined
            catch
                error:badarg -> http_date(S, Now)
            end
    end.

%% RFC 9110 §5.6.7 IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the form
%% servers send; obsolete formats are not worth a parser here.
http_date(S, Now) ->
    case
        re:run(
            S,
            "^[A-Za-z]{3}, (\\d{1,2}) ([A-Za-z]{3}) (\\d{4}) (\\d{2}):(\\d{2}):(\\d{2}) GMT$",
            [{capture, all_but_first, list}]
        )
    of
        {match, [D, Mon, Y, H, Mi, Se]} ->
            case month(string:lowercase(Mon)) of
                undefined ->
                    undefined;
                M ->
                    Date = {list_to_integer(Y), M, list_to_integer(D)},
                    case calendar:valid_date(Date) of
                        true ->
                            Secs =
                                calendar:datetime_to_gregorian_seconds(
                                    {Date, {
                                        list_to_integer(H), list_to_integer(Mi), list_to_integer(Se)
                                    }}
                                ) - 62167219200,
                            max(Secs - Now, 0);
                        false ->
                            undefined
                    end
            end;
        nomatch ->
            undefined
    end.

month("jan") -> 1;
month("feb") -> 2;
month("mar") -> 3;
month("apr") -> 4;
month("may") -> 5;
month("jun") -> 6;
month("jul") -> 7;
month("aug") -> 8;
month("sep") -> 9;
month("oct") -> 10;
month("nov") -> 11;
month("dec") -> 12;
month(_) -> undefined.

-doc """
Reject a non-https webhook URL. For chat connectors whose webhook URL IS the
credential, cleartext http would leak the token, so a stale or typo'd config
fails closed rather than transmitting it.
""".
-spec assert_webhook_https(binary(), binary()) -> ok.
assert_webhook_https(Url, Provider) ->
    case string:prefix(string:lowercase(Url), <<"https://">>) of
        nomatch ->
            fail(invalid_request(<<Provider/binary, " webhook_url must be an https:// URL.">>));
        _ ->
            ok
    end.

-doc """
Abort the current send with `Error`. Only valid inside a call made through
`thinwrap_notifications`, which turns it into `{error, Error}`.
""".
-spec fail(thinwrap_notifications:connector_error()) -> no_return().
fail(Error) ->
    throw({?THROW_TAG, Error}).
