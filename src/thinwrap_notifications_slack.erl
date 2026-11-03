-module(thinwrap_notifications_slack).
-moduledoc false.

%% Slack Incoming Webhook chat connector (webhook-URL-as-auth).
%%
%% The webhook URL IS the credential and targets the channel directly, so the
%% input `to` is unused. Slack returns plain text "ok" on success with no
%% message id, so provider_message_id is always <<>> and raw is the text.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{body := Text} = I) ->
    Url = thinwrap_notifications_input:secret(Config, webhook_url),
    Url =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Slack requires `webhook_url` in config (webhook-URL-as-auth).">>
            )
        ),
    thinwrap_notifications_error:assert_webhook_https(Url, <<"Slack">>),
    %% Passthrough keys are sent exactly as given: write Slack's own snake_case
    %% names (icon_emoji, thread_ts, unfurl_links, blocks). The passthrough
    %% query is not forwarded.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{<<"text">> => Text},
        #{<<"Content-Type">> => <<"application/json">>},
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Url, Body, Headers, []),
    Resp = text(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Resp),
    thinwrap_notifications_util:result(sent, <<>>, Resp).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), binary()) -> no_return().
fail_response(Status, RH, Resp) ->
    Msg =
        case Resp of
            <<>> -> <<"Slack HTTP ", (integer_to_binary(Status))/binary>>;
            _ -> Resp
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Resp, map_code(Status), Msg)
    ).

%% 401/403/404 all map to auth_failed — an invalid, revoked, or deleted
%% webhook URL is a credential failure.
map_code(S) when S =:= 401; S =:= 403; S =:= 404 -> auth_failed;
map_code(429) -> rate_limited;
map_code(400) -> invalid_request;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(_) -> unknown.

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
