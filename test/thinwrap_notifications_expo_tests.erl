-module(thinwrap_notifications_expo_tests).

%% Ported from the Python sibling's tests/test_expo.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) -> ?F:config(maps:merge(#{provider => expo}, Extra), Responses).

send_success_single_ticket_test() ->
    {C, P} = cfg(#{access_token => <<"tok">>}, [
        ?F:resp(200, <<"{\"data\":{\"status\":\"ok\",\"id\":\"ticket-1\"}}">>)
    ]),
    {ok, R} = ?N:send_push(C, #{
        to => <<"ExponentPushToken[xyz]">>,
        title => <<"Hi">>,
        body => <<"there">>,
        data => #{<<"k">> => <<"v">>}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"ticket-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"exp.host">>, ?F:host_of(Req)),
    ?assertEqual(<<"/--/api/v2/push/send">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer tok">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Accept">>)),
    ?assertEqual(
        #{
            <<"to">> => <<"ExponentPushToken[xyz]">>,
            <<"title">> => <<"Hi">>,
            <<"body">> => <<"there">>,
            <<"data">> => #{<<"k">> => <<"v">>}
        },
        ?F:body_json(Req)
    ).

no_auth_header_without_access_token_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"data\":[{\"status\":\"ok\",\"id\":\"t2\"}]}">>)]),
    {ok, R} = ?N:send_push(C, #{to => <<"tok">>, body => <<"hi">>}),
    %% Array-shaped data normalizes to the first ticket.
    ?assertEqual(<<"t2">>, maps:get(provider_message_id, R)),
    ?assertEqual(undefined, ?F:header(?F:last(P), <<"Authorization">>)),
    ?assertEqual(#{<<"to">> => <<"tok">>, <<"body">> => <<"hi">>}, ?F:body_json(?F:last(P))).

access_token_fun_test() ->
    {C, P} = cfg(#{access_token => fun() -> <<"ftok">> end}, [
        ?F:resp(200, <<"{\"data\":{\"status\":\"ok\",\"id\":\"t\"}}">>)
    ]),
    {ok, _} = ?N:send_push(C, #{to => <<"tok">>}),
    ?assertEqual(<<"Bearer ftok">>, ?F:header(?F:last(P), <<"Authorization">>)).

ticket_error_maps_invalid_recipient_test() ->
    Body =
        <<"{\"data\":[{\"status\":\"error\",\"message\":\"not registered\",",
            "\"details\":{\"error\":\"DeviceNotRegistered\"}}]}">>,
    {C, _} = cfg(#{}, [?F:resp(200, Body)]),
    {error, E} = ?N:send_push(C, #{to => <<"tok">>, body => <<"hi">>}),
    ?assertMatch(
        #{code := invalid_recipient, status := 200, provider_message := <<"not registered">>}, E
    ),
    ?assertEqual(#{<<"raw">> => json:decode(Body)}, maps:get(cause, E)).

ticket_error_code_table_test_() ->
    [
        ?_test(begin
            Body = json:encode(#{
                <<"data">> => #{
                    <<"status">> => <<"error">>, <<"details">> => #{<<"error">> => Code}
                }
            }),
            {C, _} = cfg(#{}, [?F:resp(200, Body)]),
            {error, E} = ?N:send_push(C, #{to => <<"tok">>}),
            ?assertMatch(#{code := Want}, E),
            ?assertEqual(<<"Expo ticket error: ", Code/binary>>, maps:get(message, E))
        end)
     || {Code, Want} <- [
            {<<"DeviceNotRegistered">>, invalid_recipient},
            {<<"MessageTooBig">>, invalid_request},
            {<<"MessageRateExceeded">>, rate_limited},
            {<<"MismatchSenderId">>, auth_failed},
            {<<"InvalidCredentials">>, auth_failed},
            {<<"SomethingNew">>, unknown}
        ]
    ].

ticket_error_without_code_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<"{\"data\":{\"status\":\"error\"}}">>)]),
    ?assertMatch(
        {error, #{code := unknown, message := <<"Expo ticket error: unknown">>}},
        ?N:send_push(C, #{to => <<"tok">>})
    ).

http_error_maps_rate_limited_test() ->
    {C, _} = cfg(#{}, [?F:resp(429, <<"{\"errors\":[{\"message\":\"slow down\"}]}">>)]),
    ?assertMatch(
        {error, #{code := rate_limited, status := 429, provider_message := <<"slow down">>}},
        ?N:send_push(C, #{to => <<"tok">>, body => <<"hi">>})
    ).

http_status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{}">>)]),
            {error, E} = ?N:send_push(C, #{to => <<"tok">>}),
            ?assertMatch(#{code := Want, status := S}, E),
            ?assertEqual(<<"Expo HTTP ", (integer_to_binary(S))/binary>>, maps:get(message, E))
        end)
     || {S, Want} <- [
            {401, auth_failed},
            {403, invalid_request},
            {400, invalid_request},
            {404, invalid_request},
            {500, provider_unavailable},
            {503, provider_unavailable},
            {302, unknown}
        ]
    ].

missing_data_ticket_is_unknown_test_() ->
    [
        ?_assertMatch(
            {error, #{
                code := unknown,
                status := 200,
                message := <<"Expo response missing `data` ticket.">>
            }},
            begin
                {C, _} = cfg(#{}, [?F:resp(200, Body)]),
                ?N:send_push(C, #{to => <<"tok">>, body => <<"hi">>})
            end
        )
     || Body <- [
            <<"{}">>, <<"{\"data\":[]}">>, <<"{\"data\":[null]}">>, <<"{\"data\":\"x\"}">>, <<>>
        ]
    ].

passthrough_merges_verbatim_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"data\":{\"status\":\"ok\",\"id\":\"t\"}}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"tok">>,
        passthrough => #{
            body => #{<<"channelId">> => <<"default">>, priority => <<"high">>},
            query => #{<<"q">> => <<"1">>}
        }
    }),
    Req = ?F:last(P),
    Body = ?F:body_json(Req),
    ?assertEqual(<<"default">>, maps:get(<<"channelId">>, Body)),
    ?assertEqual(<<"high">>, maps:get(<<"priority">>, Body)),
    %% The passthrough query is not forwarded.
    ?assertEqual(<<"https://exp.host/--/api/v2/push/send">>, maps:get(url, Req)).
