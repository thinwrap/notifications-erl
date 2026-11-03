-module(thinwrap_notifications_onesignal_tests).

%% Ported from the Python sibling's tests/test_onesignal.py, plus the OneSignal
%% case of test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{provider => 'one-signal', app_id => <<"app-uuid">>, api_key => <<"rest-api-key">>},
            Extra
        ),
        Responses
    ).

send_success_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"id\":\"notif-1\",\"recipients\":3}">>)]),
    {ok, R} = ?N:send_push(C, #{
        to => <<"sub-1">>, title => <<"Hi">>, body => <<"there">>, data => #{<<"k">> => <<"v">>}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"notif-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"onesignal.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/api/v1/notifications">>, ?F:path_of(Req)),
    ?assertEqual(<<"Basic rest-api-key">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Accept">>)),
    ?assertEqual(
        #{
            <<"app_id">> => <<"app-uuid">>,
            <<"include_subscription_ids">> => [<<"sub-1">>],
            <<"headings">> => #{<<"en">> => <<"Hi">>},
            <<"contents">> => #{<<"en">> => <<"there">>},
            <<"data">> => #{<<"k">> => <<"v">>}
        },
        ?F:body_json(Req)
    ).

minimal_body_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"id\":\"n\"}">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"sub-1">>}),
    ?assertEqual(
        #{<<"app_id">> => <<"app-uuid">>, <<"include_subscription_ids">> => [<<"sub-1">>]},
        ?F:body_json(?F:last(P))
    ).

passthrough_recipient_suppresses_subscription_ids_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"id\":\"notif-2\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"sub-1">>,
        body => <<"hi">>,
        passthrough => #{body => #{included_segments => [<<"Active Users">>]}}
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertNot(maps:is_key(<<"include_subscription_ids">>, Payload)),
    ?assertEqual([<<"Active Users">>], maps:get(<<"included_segments">>, Payload)).

null_passthrough_recipient_keeps_default_target_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"id\":\"n\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"sub-1">>, passthrough => #{body => #{<<"filters">> => null}}
    }),
    ?assertEqual([<<"sub-1">>], maps:get(<<"include_subscription_ids">>, ?F:body_json(?F:last(P)))).

http_error_maps_auth_failed_test() ->
    {C, _} = cfg(#{}, [?F:resp(401, <<"{\"errors\":[\"Invalid app_id or api key\"]}">>)]),
    ?assertMatch(
        {error, #{
            code := auth_failed, status := 401, provider_message := <<"Invalid app_id or api key">>
        }},
        ?N:send_push(C, #{to => <<"sub-1">>, body => <<"hi">>})
    ).

http_error_message_sources_test_() ->
    [
        ?_assertMatch(
            {error, #{provider_message := Want}},
            begin
                {C, _} = cfg(#{}, [?F:resp(400, Body)]),
                ?N:send_push(C, #{to => <<"s">>})
            end
        )
     || {Body, Want} <- [
            {<<"{\"errors\":{\"invalid_aliases\":{\"external_id\":[\"x\"]}}}">>,
                <<"{\"invalid_aliases\":{\"external_id\":[\"x\"]}}">>},
            {<<"{\"errors\":[1],\"message\":\"m\"}">>, <<"m">>},
            {<<"{\"message\":\"m2\"}">>, <<"m2">>},
            {<<"{}">>, <<"OneSignal 400">>}
        ]
    ].

status_table_test_() ->
    [
        ?_assertMatch(
            {error, #{code := Want, status := S}},
            begin
                {C, _} = cfg(#{}, [?F:resp(S, <<"{}">>)]),
                ?N:send_push(C, #{to => <<"s">>})
            end
        )
     || {S, Want} <- [
            {400, invalid_request},
            {401, auth_failed},
            {403, unknown},
            {404, invalid_request},
            {429, rate_limited},
            {500, provider_unavailable},
            {502, provider_unavailable},
            {503, provider_unavailable}
        ]
    ].

invalid_recipient_marker_on_200_test() ->
    Body = <<"{\"id\":\"\",\"errors\":[\"All included players are not subscribed\"]}">>,
    {C, _} = cfg(#{}, [?F:resp(200, Body)]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient,
            status := 200,
            provider_message := <<"All included players are not subscribed">>
        }},
        ?N:send_push(C, #{to => <<"sub-1">>, body => <<"hi">>})
    ).

invalid_recipient_markers_test_() ->
    [
        ?_assertMatch(
            {error, #{code := Want}},
            begin
                {C, _} = cfg(#{}, [?F:resp(200, json:encode(#{<<"errors">> => Errors}))]),
                ?N:send_push(C, #{to => <<"s">>})
            end
        )
     || {Errors, Want} <- [
            {[<<"other">>, <<"Invalid_Player_Ids present">>], invalid_recipient},
            {[<<"No Subscriptions">>], invalid_recipient},
            {[<<"invalid_external_user_ids">>], invalid_recipient},
            {[<<"something else">>], invalid_request},
            {[], invalid_request},
            {#{<<"invalid_external_user_ids">> => [<<"u">>]}, invalid_recipient},
            {#{<<"invalid_aliases">> => #{<<"external_id">> => [<<"x">>]}}, invalid_recipient},
            {#{<<"invalid_player_ids">> => []}, invalid_request},
            {#{<<"invalid_aliases">> => #{}}, invalid_request},
            {<<"a string">>, invalid_request}
        ]
    ].

errors_map_with_odd_values_still_classifies_test() ->
    %% test_request_guards.py: a vendor value that the request encoders would
    %% reject must not crash the error path (the Python case uses NaN, which
    %% OTP's decoder rejects; a huge float and nested values stand in).
    Body =
        <<"{\"id\":\"\",\"errors\":{\"invalid_player_ids\":[\"x\"],\"n\":1.5e308,\"z\":[null,{}]}}">>,
    {C, _} = cfg(#{api_key => <<"k">>, app_id => <<"app">>}, [?F:resp(200, Body)]),
    {error, E} = ?N:send_push(C, #{to => <<"s">>, body => <<"hi">>}),
    ?assertMatch(#{code := invalid_recipient}, E),
    ?assertEqual(
        json:decode(maps:get(message, E)),
        maps:get(<<"errors">>, json:decode(Body))
    ).

no_id_is_invalid_request_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<"{\"recipients\":0}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_request,
            status := 200,
            message := <<"OneSignal returned no notification id">>,
            cause := #{<<"raw">> := #{<<"recipients">> := 0}}
        }},
        ?N:send_push(C, #{to => <<"sub-1">>, body => <<"hi">>})
    ).

v2_key_uses_current_endpoint_and_key_scheme_test() ->
    {C, P} = cfg(#{api_key => <<"os_v2_app_abc123">>}, [?F:resp(200, <<"{\"id\":\"notif-3\"}">>)]),
    {ok, R} = ?N:send_push(C, #{to => <<"sub-1">>, body => <<"hi">>}),
    ?assertEqual(<<"notif-3">>, maps:get(provider_message_id, R)),
    Req = ?F:last(P),
    ?assertEqual(<<"api.onesignal.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/notifications">>, ?F:path_of(Req)),
    ?assertEqual(<<"push">>, ?F:qget(Req, <<"c">>)),
    ?assertEqual(<<"Key os_v2_app_abc123">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual([<<"sub-1">>], maps:get(<<"include_subscription_ids">>, ?F:body_json(Req))).

legacy_key_keeps_v1_endpoint_and_basic_test() ->
    {C, P} = cfg(#{api_key => <<"NGEwZGZmMjYtMTQ2Ny00">>}, [
        ?F:resp(200, <<"{\"id\":\"notif-4\"}">>)
    ]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"sub-1">>, body => <<"hi">>, passthrough => #{query => #{<<"q">> => <<"1">>}}
    }),
    Req = ?F:last(P),
    %% The passthrough query is not forwarded.
    ?assertEqual(<<"https://onesignal.com/api/v1/notifications">>, maps:get(url, Req)),
    ?assertEqual(<<"Basic NGEwZGZmMjYtMTQ2Ny00">>, ?F:header(Req, <<"Authorization">>)).

caller_targeting_suppresses_default_target_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{api_key => <<"os_v2_app_abc123">>}, [
                ?F:resp(200, <<"{\"id\":\"notif-5\"}">>)
            ]),
            {ok, _} = ?N:send_push(C, #{
                to => <<"sub-1">>, body => <<"hi">>, passthrough => #{body => Targeting}
            }),
            Payload = ?F:body_json(?F:last(P)),
            [?assertEqual(V, maps:get(K, Payload)) || K := V <- Targeting],
            maps:is_key(<<"include_subscription_ids">>, Targeting) orelse
                ?assertNot(maps:is_key(<<"include_subscription_ids">>, Payload))
        end)
     || Targeting <- [
            #{
                <<"include_aliases">> => #{<<"external_id">> => [<<"user-1">>]},
                <<"target_channel">> => <<"push">>
            },
            #{<<"include_subscription_ids">> => [<<"sub-9">>]},
            #{
                <<"filters">> => [
                    #{
                        <<"field">> => <<"tag">>,
                        <<"key">> => <<"level">>,
                        <<"relation">> => <<">">>,
                        <<"value">> => <<"10">>
                    }
                ]
            },
            #{<<"include_email_tokens">> => [<<"a@example.com">>]},
            #{<<"include_phone_numbers">> => [<<"+15555550100">>]},
            #{<<"excluded_segments">> => [<<"Inactive">>]},
            #{<<"include_player_ids">> => [<<"p">>]},
            #{<<"include_external_user_ids">> => [<<"e">>]}
        ]
    ].

with_id_and_partial_errors_is_success_test() ->
    %% OneSignal create-notification: with an id the notification exists; the
    %% errors list names only the targets that were skipped.
    Body = <<"{\"id\":\"notif-1\",\"errors\":{\"invalid_player_ids\":[\"bad-1\"]}}">>,
    {C, _} = cfg(#{}, [?F:resp(200, Body)]),
    {ok, R} = ?N:send_push(C, #{to => <<"sub-1">>, body => <<"hi">>}),
    ?assertMatch(#{success := true, provider_message_id := <<"notif-1">>}, R),
    ?assertEqual(
        #{<<"invalid_player_ids">> => [<<"bad-1">>]}, maps:get(<<"errors">>, maps:get(raw, R))
    ).
