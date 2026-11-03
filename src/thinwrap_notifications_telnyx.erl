-module(thinwrap_notifications_telnyx).
-moduledoc false.

%% Telnyx SMS connector (JSON v2 messages API, Bearer auth, snake_case).
%%
%% Telnyx wraps success responses in a JSON:API {data: {...}} envelope;
%% provider_message_id unwraps data.id and raw preserves the full envelope.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.telnyx.com/v2/messages">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    %% Passthrough keys are sent exactly as given: write Telnyx's own
    %% snake_case names (messaging_profile_id, webhook_url, …).
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    HasProfile =
        not lists:member(
            maps:get(<<"messaging_profile_id">>, thinwrap_notifications_passthrough:body(I), null),
            [null, undefined]
        ),
    (From =/= <<>> orelse HasProfile) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<
                    "Telnyx requires `from` (input or config) or a `messaging_profile_id` "
                    "passthrough field."
                >>
            )
        ),
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        thinwrap_notifications_util:put_nonempty(<<"from">>, From, #{
            <<"to">> => maps:get(to, I), <<"text">> => maps:get(body, I)
        }),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> =>
                <<"Bearer ", (thinwrap_notifications_input:secret(Config, api_key))/binary>>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(
            thinwrap_notifications_json:path(Raw, [<<"data">>, <<"id">>])
        ),
        Raw
    ).

-spec fail(integer(), map(), term()) -> no_return().
fail(Status, RH, Raw) ->
    First =
        case thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"errors">>)) of
            [E | _] -> E;
            _ -> undefined
        end,
    Code = thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"code">>)),
    Msg = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"detail">>)),
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"title">>)),
        <<"Telnyx HTTP ", (integer_to_binary(Status))/binary>>
    ]),
    Pointer = thinwrap_notifications_json:str(
        thinwrap_notifications_json:path(First, [<<"source">>, <<"pointer">>])
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Code, Pointer), Msg
        )
    ).

%% 10002 "Invalid phone number" names the field in source.pointer (JSON
%% Pointer); when it is the destination, the recipient is the problem.
map_code(_, <<"10002">>, <<"/to">>) ->
    invalid_recipient;
map_code(S, Code, _) ->
    %% The vendor code is finer than the status (a 422 can be a bad 'to' or a
    %% bad 'from'), so it decides first; the status is the fallback.
    case code(Code) of
        undefined -> status_code(S);
        Mapped -> Mapped
    end.

status_code(S) when S =:= 401; S =:= 403 -> auth_failed;
status_code(429) -> rate_limited;
status_code(S) when S >= 500 -> provider_unavailable;
status_code(S) when S >= 400 -> invalid_request;
status_code(_) -> unknown.

%% Telnyx `errors[0].code` is a numeric string. Only the synchronous codes are
%% listed: 400xx delivery errors arrive solely in the message.finalized
%% webhook, never in the send response.
%% https://developers.telnyx.com/development/api-fundamentals/api-errors
%% https://developers.telnyx.com/docs/messaging/messages/error-codes
code(C) ->
    case C of
        %% 40300 blocked by STOP (opted out), 40309 invalid destination
        %% region, 40310 invalid 'to' address
        _ when C =:= <<"40300">>; C =:= <<"40309">>; C =:= <<"40310">> ->
            invalid_recipient;
        %% 10009 authentication failed, 10010 authorization failed, 20001
        %% invalid API key secret, 20006 expired access token, 40311/40313
        %% invalid/missing messaging profile secret
        _ when
            C =:= <<"10009">>;
            C =:= <<"10010">>;
            C =:= <<"20001">>;
            C =:= <<"20006">>;
            C =:= <<"40311">>;
            C =:= <<"40313">>
        ->
            auth_failed;
        %% 10011 too many requests, 40318 message queue full
        _ when C =:= <<"10011">>; C =:= <<"40318">> ->
            rate_limited;
        _ ->
            %% 40305 invalid 'from', 40314 messaging disabled, 40316 no
            %% content, the other 403xx request errors, 10002/10004/10015 bad
            %% input, 20100 insufficient funds
            case
                lists:member(C, [
                    <<"40301">>,
                    <<"40302">>,
                    <<"40303">>,
                    <<"40304">>,
                    <<"40305">>,
                    <<"40306">>,
                    <<"40307">>,
                    <<"40308">>,
                    <<"40314">>,
                    <<"40316">>,
                    <<"40317">>,
                    <<"40319">>,
                    <<"40320">>,
                    <<"40321">>,
                    <<"40322">>,
                    <<"40323">>,
                    <<"40324">>,
                    <<"40325">>,
                    <<"40328">>,
                    <<"40331">>,
                    <<"40333">>,
                    <<"10002">>,
                    <<"10004">>,
                    <<"10015">>,
                    <<"20100">>
                ])
            of
                true -> invalid_request;
                false -> undefined
            end
    end.
