-module(thinwrap_notifications_line).
-moduledoc false.

%% LINE Messaging API (Push) chat connector (POST /v2/bot/message/push).
%%
%% `to` is required (userId / groupId / roomId from a LINE webhook event). The
%% body is synthesized into a single text message; a caller wanting the full
%% Message-object surface (sticker, image, flex, template, ...) supplies a
%% `messages` list via passthrough.body, which replaces the synthesized one.
%% LINE's wire keys are camelCase end-to-end, so passthrough.body is
%% forwarded verbatim (no casing transform).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.line.me/v2/bot/message/push">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{body := Text, to := To} = I) ->
    To =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"LINE requires `to` (userId / groupId / roomId).">>
            )
        ),
    Token = thinwrap_notifications_input:secret(Config, channel_access_token),
    %% LINE push is JSON body only, no query params: don't forward a query
    %% string the endpoint won't read.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{
            <<"to">> => To,
            <<"messages">> => [#{<<"type">> => <<"text">>, <<"text">> => Text}]
        },
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Token/binary>>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    %% LINE Push returns {sentMessages: [{id, quoteToken?}, ...]} — one entry
    %% per message. Surface the first sentMessage id.
    thinwrap_notifications_util:result(sent, first_message_id(Raw), Raw).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Message = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Raw, <<"message">>)
    ),
    Msg =
        case Message of
            <<>> -> <<"LINE HTTP ", (integer_to_binary(Status))/binary>>;
            _ -> Message
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Message), Msg
        )
    ).

first_message_id(Raw) ->
    case
        thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"sentMessages">>))
    of
        [First | _] ->
            thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"id">>));
        _ ->
            <<>>
    end.

map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(400, Message) ->
    case
        re:run(string:lowercase(Message), "not found|userid|user id", [unicode, {capture, none}])
    of
        match -> invalid_recipient;
        nomatch -> invalid_request
    end;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(_, _) ->
    unknown.
