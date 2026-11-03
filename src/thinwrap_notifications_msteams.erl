-module(thinwrap_notifications_msteams).
-moduledoc false.

%% Microsoft Teams chat connector (Workflows / Incoming Webhook + Adaptive
%% Card). The input `to` is ignored — the webhook URL targets the channel.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% The Adaptive Card schema URI. The Teams renderer never validates $schema (it
%% keys off type/version); https serves the schema directly, so https is used.
-define(ADAPTIVE_CARD_SCHEMA, <<"https://adaptivecards.io/schemas/adaptive-card.json">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{body := Text} = I) ->
    Url = thinwrap_notifications_input:secret(Config, webhook_url),
    Url =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"MS Teams requires `webhookUrl` in config (webhook-URL-as-auth).">>
            )
        ),
    thinwrap_notifications_error:assert_webhook_https(Url, <<"MS Teams">>),
    %% A default Adaptive Card v1.4 with a single TextBlock carrying the body.
    %% Supply "attachments" via passthrough to send a full custom card — the
    %% list replaces the synthesized value on merge.
    Card = #{
        <<"type">> => <<"AdaptiveCard">>,
        <<"$schema">> => ?ADAPTIVE_CARD_SCHEMA,
        <<"version">> => <<"1.4">>,
        <<"body">> => [#{<<"type">> => <<"TextBlock">>, <<"text">> => Text, <<"wrap">> => true}]
    },
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{
            <<"type">> => <<"message">>,
            <<"attachments">> => [
                #{
                    <<"contentType">> => <<"application/vnd.microsoft.card.adaptive">>,
                    <<"content">> => Card
                }
            ]
        },
        #{<<"Content-Type">> => <<"application/json">>},
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Url, Body, Headers, []),
    %% No success payload carries a message id, so provider_message_id is
    %% always empty and raw is the response text.
    Resp = text(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Resp),
    %% A Workflows ("When a Teams webhook request is received") trigger with no
    %% Response action answers 202 Accepted, with whatever body, once the
    %% request is accepted — that is the delivered case.
    Status =:= 202 orelse check_200(Url, RH, Resp),
    thinwrap_notifications_util:result(sent, <<>>, Resp).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), binary()) -> no_return().
fail_response(Status, RH, Resp) ->
    Msg =
        case Resp of
            <<>> -> <<"MS Teams HTTP ", (integer_to_binary(Status))/binary>>;
            _ -> Resp
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Resp, map_code(Status, Resp), Msg
        )
    ).

check_200(Url, RH, Resp) ->
    %% A legacy Office 365 connector STILL returns HTTP 200 on failure
    %% (including throttling), with an error string in the body, e.g.
    %% "...Teams endpoint returned HTTP error 429 with ContextId...".
    case
        re:run(Resp, "HTTP error ([0-9]{3})", [caseless, unicode, {capture, all_but_first, binary}])
    of
        {match, [Code]} ->
            Effective = binary_to_integer(Code),
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:vendor_error(
                    Effective, RH, Resp, map_code(Effective, Resp), Resp
                )
            );
        nomatch ->
            ok
    end,
    %% Only a legacy connector host promises the literal "1" on success; a
    %% Workflows URL may answer 200 with an empty or custom body.
    case is_legacy_connector_url(Url) andalso py_strip(Resp) =/= <<"1">> of
        true ->
            Msg =
                case Resp of
                    <<>> -> <<"MS Teams webhook failed">>;
                    _ -> Resp
                end,
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:vendor_error(502, RH, Resp, map_code(502, Resp), Msg)
            );
        false ->
            true
    end.

%% True for an Office 365 connector (Incoming Webhook) host, whose success body
%% is the plain text "1".
is_legacy_connector_url(Url) ->
    Host = hostname(Url),
    Host =:= <<"outlook.office.com">> orelse
        binary:longest_common_suffix([Host, <<".webhook.office.com">>]) =:= 19.

%% The host the way Python's `urlsplit(url).hostname` reads it: the netloc up
%% to the first `/`, `?` or `#`, after the last `@`, without the port or IPv6
%% brackets, lower-cased.
hostname(Url) ->
    Rest =
        case binary:split(Url, <<"//">>) of
            [_, After] -> After;
            [_] -> <<>>
        end,
    Netloc = hd(binary:split(Rest, [<<"/">>, <<"?">>, <<"#">>])),
    HostPort = lists:last(binary:split(Netloc, <<"@">>, [global])),
    Host =
        case HostPort of
            <<"[", V6/binary>> -> hd(binary:split(V6, <<"]">>));
            _ -> hd(binary:split(HostPort, <<":">>))
        end,
    string:lowercase(Host).

%% Python's `str.strip()`: trims the characters `str.isspace()` accepts.
py_strip(B) ->
    case unicode:characters_to_list(B) of
        Chars when is_list(Chars) ->
            L = lists:dropwhile(fun is_py_space/1, Chars),
            R = lists:dropwhile(fun is_py_space/1, lists:reverse(L)),
            unicode:characters_to_binary(lists:reverse(R));
        _ ->
            %% A response body that is not UTF-8 cannot be the "1" success
            %% marker; returned as-is so the caller reports the failure.
            B
    end.

is_py_space(C) when C >= 16#09, C =< 16#0D -> true;
is_py_space(C) when C >= 16#1C, C =< 16#20 -> true;
is_py_space(C) when C >= 16#2000, C =< 16#200A -> true;
is_py_space(C) ->
    lists:member(C, [16#85, 16#A0, 16#1680, 16#2028, 16#2029, 16#202F, 16#205F, 16#3000]).

%% Teams-specific quirk: revoked or malformed webhook URLs return HTTP 400 with
%% a plain-text body containing "Invalid webhook URL" (not 404 like
%% Slack/Discord) — special-cased to auth_failed.
map_code(400, Text) ->
    case binary:match(string:lowercase(Text), <<"invalid webhook">>) of
        nomatch -> invalid_request;
        _ -> auth_failed
    end;
map_code(S, _) when S =:= 401; S =:= 403; S =:= 404 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(_, _) ->
    unknown.

%% The response body as UTF-8 text, each ill-formed sequence replaced by
%% U+FFFD the way Python's `bytes.decode("utf-8", "replace")` does it (one
%% replacement per maximal ill-formed subpart), so a non-UTF-8 vendor body
%% still becomes an error, never a crash.
text(B) -> iolist_to_binary(text_parts(B)).

text_parts(B) ->
    case unicode:characters_to_binary(B) of
        Ok when is_binary(Ok) ->
            [Ok];
        {_, Good, Bad} ->
            Skip = bad_prefix(Bad),
            <<_:Skip/binary, Rest/binary>> = Bad,
            [Good, <<16#FFFD/utf8>> | text_parts(Rest)]
    end.

%% Length of the maximal ill-formed subpart at the head of `Bin` (Unicode
%% §3.9 / W3C "U+FFFD substitution of maximal subparts").
bad_prefix(<<C, Rest/binary>>) when C >= 16#C2, C =< 16#DF -> 1 + conts(Rest, 1, 16#80, 16#BF);
bad_prefix(<<16#E0, Rest/binary>>) -> 1 + conts(Rest, 2, 16#A0, 16#BF);
bad_prefix(<<16#ED, Rest/binary>>) -> 1 + conts(Rest, 2, 16#80, 16#9F);
bad_prefix(<<C, Rest/binary>>) when C >= 16#E1, C =< 16#EF -> 1 + conts(Rest, 2, 16#80, 16#BF);
bad_prefix(<<16#F0, Rest/binary>>) -> 1 + conts(Rest, 3, 16#90, 16#BF);
bad_prefix(<<16#F4, Rest/binary>>) -> 1 + conts(Rest, 3, 16#80, 16#8F);
bad_prefix(<<C, Rest/binary>>) when C >= 16#F1, C =< 16#F3 -> 1 + conts(Rest, 3, 16#80, 16#BF);
bad_prefix(_) -> 1.

%% How many valid continuation bytes follow (the first one constrained to
%% Lo..Hi), stopping before the sequence would be complete.
conts(<<C, Rest/binary>>, Need, Lo, Hi) when Need > 1, C >= Lo, C =< Hi ->
    1 + conts(Rest, Need - 1, 16#80, 16#BF);
conts(_, _, _, _) ->
    0.
