-module(thinwrap_notifications_d7networks).
-moduledoc false.

%% D7 Networks SMS connector (Messaging API v1, Bearer auth, snake_case wire).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.d7networks.com/messages/v1/send">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    Originator = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    Originator =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"D7 Networks requires `from` in either the input or the config.">>
            )
        ),
    %% D7's wire shape is the most nested of any SMS provider: per-message
    %% fields live inside messages[], global fields inside message_globals.
    %% Passthrough keys are sent exactly as given: write D7's own snake_case
    %% names (message_globals, …); a passthrough message_globals deep-merges.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{
            <<"messages">> => [
                #{
                    <<"channel">> => <<"sms">>,
                    <<"recipients">> => [maps:get(to, I)],
                    <<"content">> => maps:get(body, I),
                    <<"msg_type">> => <<"text">>
                }
            ],
            <<"message_globals">> => #{<<"originator">> => Originator}
        },
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> =>
                <<"Bearer ", (thinwrap_notifications_input:secret(Config, api_token))/binary>>,
            <<"Accept">> => <<"application/json">>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"request_id">>)),
        Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    %% Body shape: {code,detail}; both are surfaced and kept on cause.raw.
    Code = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Raw, <<"code">>)
    ),
    Msg =
        case
            thinwrap_notifications_json:str(
                thinwrap_notifications_json:get(Raw, <<"detail">>)
            )
        of
            <<>> ->
                string:trim(
                    <<"D7 Networks HTTP ", (integer_to_binary(Status))/binary, " ", Code/binary>>
                );
            Detail ->
                Detail
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
