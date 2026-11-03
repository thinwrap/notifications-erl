-module(thinwrap_notifications_resend).
-moduledoc false.

%% Resend email connector (JSON emails API).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.resend.com/emails">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    Key = thinwrap_notifications_input:secret(Config, api_key),
    %% Passthrough keys are sent exactly as given: write Resend's own snake_case
    %% names (scheduled_at, …). The passthrough query is not forwarded.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Key/binary>>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"id">>)), Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Raw, <<"message">>)
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Msg), Msg
        )
    ).

build_body(Config, I) ->
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    Base = #{
        <<"from">> => thinwrap_notifications_util:format_mailbox(
            thinwrap_notifications_util:cfg(Config, sender_name), From
        ),
        <<"to">> => [maps:get(to, I)],
        <<"subject">> => maps:get(subject, I)
    },
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"html">>, maps:get(html, I)},
            {<<"text">>, maps:get(text, I)},
            {<<"cc">>, maps:get(cc, I)},
            {<<"bcc">>, maps:get(bcc, I)},
            {<<"reply_to">>, maps:get(reply_to, I)},
            {<<"headers">>, maps:get(headers, I)},
            {<<"tags">>, [#{<<"name">> => <<"tag">>, <<"value">> => T} || T <- maps:get(tags, I)]},
            {<<"attachments">>, [attachment(A) || A <- maps:get(attachments, I)]}
        ]
    ).

attachment(#{filename := F, content := C, content_type := CT, content_id := Cid}) ->
    A = #{<<"filename">> => F, <<"content">> => thinwrap_notifications_util:b64(C)},
    %% Resend: "You can embed images using the content id parameter for the
    %% attachment" (referenced as <img src="cid:...">).
    thinwrap_notifications_util:put_nonempty(
        <<"content_id">>, Cid, thinwrap_notifications_util:put_nonempty(<<"content_type">>, CT, A)
    ).

%% The Resend (HTTP status, message) truth table.
map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(404, _) ->
    invalid_request;
map_code(S, Msg) when S =:= 422; S =:= 400 ->
    case re:run(Msg, "recipient|email address", [caseless, unicode, {capture, none}]) of
        match -> invalid_recipient;
        nomatch -> invalid_request
    end;
map_code(_, _) ->
    unknown.
