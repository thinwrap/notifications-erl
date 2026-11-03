-module(thinwrap_notifications_expo).
-moduledoc false.

%% Expo push connector (exp.host push API).
%%
%% Expo's API is camelCase-native, so the caller's passthrough body merges
%% verbatim (no casing transform). Expo answers HTTP 200 even for soft errors:
%% the returned ticket's status is inspected after the HTTP layer, and status
%% "error" maps to a connector error.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://exp.host/--/api/v2/push/send">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    Body0 = #{<<"to">> => maps:get(to, I)},
    Body1 = lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Body0,
        [
            {<<"title">>, maps:get(title, I)},
            {<<"body">>, maps:get(body, I)},
            {<<"data">>, maps:get(data, I)}
        ]
    ),
    Headers0 = #{
        <<"Content-Type">> => <<"application/json">>, <<"Accept">> => <<"application/json">>
    },
    Headers1 =
        case thinwrap_notifications_input:secret(Config, access_token) of
            <<>> -> Headers0;
            Token -> Headers0#{<<"Authorization">> => <<"Bearer ", Token/binary>>}
        end,
    %% The passthrough query is not forwarded.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(Body1, Headers1, [], I),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse error_response(Status, RH, Raw),
    Ticket =
        case first_ticket(thinwrap_notifications_json:get(Raw, <<"data">>)) of
            undefined ->
                Msg = <<"Expo response missing `data` ticket.">>,
                thinwrap_notifications_error:fail(
                    thinwrap_notifications_error:new(unknown, #{
                        status => Status,
                        message => Msg,
                        provider_message => Msg,
                        cause => #{<<"raw">> => Raw}
                    })
                );
            T ->
                T
        end,
    case thinwrap_notifications_json:str(thinwrap_notifications_json:get(Ticket, <<"status">>)) of
        <<"error">> -> ticket_error(Ticket, Raw, Status);
        _ -> ok
    end,
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Ticket, <<"id">>)),
        Raw
    ).

%% Expo's data field is a single ticket object OR an array of tickets; the
%% first ticket, or `undefined` when absent.
first_ticket([null | _]) -> undefined;
first_ticket([T | _]) -> T;
first_ticket(#{} = T) -> T;
first_ticket(_) -> undefined.

-spec ticket_error(term(), term(), integer()) -> no_return().
ticket_error(Ticket, Raw, HttpStatus) ->
    ErrorCode = thinwrap_notifications_json:str(
        thinwrap_notifications_json:path(Ticket, [<<"details">>, <<"error">>])
    ),
    Msg =
        case
            thinwrap_notifications_json:str(thinwrap_notifications_json:get(Ticket, <<"message">>))
        of
            <<>> ->
                <<"Expo ticket error: ",
                    (case ErrorCode of
                        <<>> -> <<"unknown">>;
                        _ -> ErrorCode
                    end)/binary>>;
            M ->
                M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:new(ticket_code(ErrorCode), #{
            status => HttpStatus,
            message => Msg,
            provider_message => Msg,
            cause => #{<<"raw">> => Raw}
        })
    ).

%% Expo body-layer ticket error codes (returned on HTTP 200 under
%% data[].details.error); unmapped codes fall back to unknown.
ticket_code(<<"DeviceNotRegistered">>) -> invalid_recipient;
ticket_code(<<"MessageTooBig">>) -> invalid_request;
ticket_code(<<"MessageRateExceeded">>) -> rate_limited;
ticket_code(<<"MismatchSenderId">>) -> auth_failed;
ticket_code(<<"InvalidCredentials">>) -> auth_failed;
ticket_code(_) -> unknown.

-spec error_response(integer(), map(), term()) -> no_return().
error_response(Status, RH, Raw) ->
    Msg0 =
        case thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"errors">>)) of
            [First | _] ->
                thinwrap_notifications_json:str(
                    thinwrap_notifications_json:get(First, <<"message">>)
                );
            _ ->
                <<>>
        end,
    Msg =
        case Msg0 of
            <<>> -> <<"Expo HTTP ", (integer_to_binary(Status))/binary>>;
            _ -> Msg0
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

map_code(401) -> auth_failed;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
