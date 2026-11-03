-module(thinwrap_notifications_wonderpush_tests).

%% Ported from the Python sibling's tests/test_wonderpush.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(maps:merge(#{provider => wonderpush, access_token => <<"tok">>}, Extra), Responses).

send_success_test() ->
    {C, P} = cfg(#{application_id => <<"app-1">>}, [?F:resp(200, <<"{\"id\":\"delivery-1\"}">>)]),
    {ok, R} = ?N:send_push(C, #{
        to => <<"user-1">>, title => <<"Hi">>, body => <<"there">>, data => #{<<"k">> => <<"v">>}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"delivery-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"management-api.wonderpush.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v1/deliveries">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer tok">>, ?F:header(Req, <<"Authorization">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"app-1">>, maps:get(<<"applicationId">>, Payload)),
    ?assertEqual([<<"user-1">>], maps:get(<<"targetUserIds">>, Payload)),
    %% Doc shape: alert.title/alert.text, custom data under push.custom.
    ?assertEqual(
        #{
            <<"alert">> => #{<<"title">> => <<"Hi">>, <<"text">> => <<"there">>},
            <<"push">> => #{<<"custom">> => #{<<"k">> => <<"v">>}}
        },
        maps:get(<<"notification">>, Payload)
    ).

falls_back_to_notification_id_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"notificationId\":\"n-9\"}">>)]),
    {ok, R} = ?N:send_push(C, #{to => <<"user-1">>, body => <<"hi">>}),
    ?assertEqual(<<"n-9">>, maps:get(provider_message_id, R)),
    %% No application_id set -> not in body.
    ?assertNot(maps:is_key(<<"applicationId">>, ?F:body_json(?F:last(P)))).

no_notification_when_nothing_to_show_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{}">>)]),
    {ok, R} = ?N:send_push(C, #{to => <<"user-1">>}),
    ?assertEqual(<<>>, maps:get(provider_message_id, R)),
    ?assertEqual(#{<<"targetUserIds">> => [<<"user-1">>]}, ?F:body_json(?F:last(P))).

not_found_maps_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [?F:resp(404, <<"{\"error\":{\"message\":\"user not found\"}}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient, status := 404, provider_message := <<"user not found">>
        }},
        ?N:send_push(C, #{to => <<"user-1">>, body => <<"hi">>})
    ).

unauthorized_maps_auth_failed_test() ->
    {C, _} = cfg(#{access_token => <<"bad">>}, [
        ?F:resp(401, <<"{\"error\":{\"message\":\"bad token\"}}">>)
    ]),
    ?assertMatch(
        {error, #{code := auth_failed}}, ?N:send_push(C, #{to => <<"user-1">>, body => <<"hi">>})
    ).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{}">>)]),
            {error, E} = ?N:send_push(C, #{to => <<"u">>}),
            ?assertMatch(#{code := Want, status := S}, E),
            ?assertEqual(
                <<"WonderPush HTTP ", (integer_to_binary(S))/binary>>, maps:get(provider_message, E)
            )
        end)
     || {S, Want} <- [
            {400, invalid_request},
            {403, invalid_request},
            {422, invalid_request},
            {429, rate_limited},
            {500, provider_unavailable},
            {502, provider_unavailable},
            {503, provider_unavailable},
            {302, unknown}
        ]
    ].

passthrough_platform_alert_fields_deep_merge_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"id\":\"delivery-2\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"user-1">>,
        title => <<"Hi">>,
        body => <<"there">>,
        data => #{<<"k">> => <<"v">>},
        passthrough => #{
            body => #{
                notification => #{
                    alert => #{
                        ios => #{sound => <<"default">>, badge => 3, subtitle => <<"Sub">>},
                        android => #{sound => <<"ding">>}
                    },
                    push => #{custom => #{extra => <<"1">>}}
                }
            }
        }
    }),
    Notification = maps:get(<<"notification">>, ?F:body_json(?F:last(P))),
    ?assertEqual(
        #{
            <<"title">> => <<"Hi">>,
            <<"text">> => <<"there">>,
            <<"ios">> => #{
                <<"sound">> => <<"default">>, <<"badge">> => 3, <<"subtitle">> => <<"Sub">>
            },
            <<"android">> => #{<<"sound">> => <<"ding">>}
        },
        maps:get(<<"alert">>, Notification)
    ),
    ?assertEqual(
        #{<<"custom">> => #{<<"k">> => <<"v">>, <<"extra">> => <<"1">>}},
        maps:get(<<"push">>, Notification)
    ).

passthrough_target_and_query_forwarded_test() ->
    %% A passthrough targetUserIds replaces the default; unlike the other push
    %% connectors, WonderPush forwards the passthrough query.
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"id\":\"d\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"user-1">>,
        passthrough => #{
            body => #{<<"targetUserIds">> => [<<"a">>, <<"b">>]},
            query => #{<<"accessToken">> => <<"q">>}
        }
    }),
    Req = ?F:last(P),
    ?assertEqual([<<"a">>, <<"b">>], maps:get(<<"targetUserIds">>, ?F:body_json(Req))),
    ?assertEqual(<<"q">>, ?F:qget(Req, <<"accessToken">>)).
