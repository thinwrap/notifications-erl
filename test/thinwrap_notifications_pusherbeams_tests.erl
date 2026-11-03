-module(thinwrap_notifications_pusherbeams_tests).

%% Ported from the Python sibling's tests/test_pusherbeams.py, plus the Pusher
%% Beams case of test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{provider => 'pusher-beams', instance_id => <<"inst-1">>, secret_key => <<"sk">>},
            Extra
        ),
        Responses
    ).

send_success_synthesizes_platforms_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"publishId\":\"pub-1\"}">>)]),
    {ok, R} = ?N:send_push(C, #{
        to => <<"user-1">>, title => <<"Hi">>, body => <<"there">>, data => #{<<"k">> => <<"v">>}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"pub-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"inst-1.pushnotifications.pusher.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/publish_api/v1/instances/inst-1/publishes/users">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer sk">>, ?F:header(Req, <<"Authorization">>)),
    Payload = ?F:body_json(Req),
    N = #{<<"title">> => <<"Hi">>, <<"body">> => <<"there">>},
    D = #{<<"k">> => <<"v">>},
    ?assertEqual([<<"user-1">>], maps:get(<<"users">>, Payload)),
    ?assertEqual(#{<<"notification">> => N, <<"data">> => D}, maps:get(<<"fcm">>, Payload)),
    %% Beams publish-payloads doc: apns is Apple's payload, custom data under apns.data.
    ?assertEqual(
        #{<<"aps">> => #{<<"alert">> => N}, <<"data">> => D}, maps:get(<<"apns">>, Payload)
    ),
    ?assertEqual(#{<<"notification">> => N, <<"data">> => D}, maps:get(<<"web">>, Payload)).

interests_routing_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"publishId\":\"pub-2\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"ignored">>,
        title => <<"Hi">>,
        body => <<"b">>,
        passthrough => #{body => #{interests => [<<"news">>]}}
    }),
    Req = ?F:last(P),
    ?assertEqual(<<"/publish_api/v1/instances/inst-1/publishes/interests">>, ?F:path_of(Req)),
    Payload = ?F:body_json(Req),
    %% interests present -> no default users.
    ?assertNot(maps:is_key(<<"users">>, Payload)),
    ?assertEqual([<<"news">>], maps:get(<<"interests">>, Payload)).

passthrough_users_replace_default_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"publishId\":\"p\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"ignored">>, passthrough => #{body => #{<<"users">> => [<<"a">>, <<"b">>]}}
    }),
    Req = ?F:last(P),
    ?assertEqual(<<"/publish_api/v1/instances/inst-1/publishes/users">>, ?F:path_of(Req)),
    ?assertEqual([<<"a">>, <<"b">>], maps:get(<<"users">>, ?F:body_json(Req))).

publish_api_error_table_test_() ->
    %% pusher.com/docs/beams/reference/publish-api error responses.
    [
        ?_assertMatch(
            {error, #{code := Want, status := S, provider_message := <<"x">>}},
            begin
                {C, _} = cfg(#{}, [?F:resp(S, <<"{\"error\":\"x\",\"description\":\"y\"}">>)]),
                ?N:send_push(C, #{to => <<"user-1">>, body => <<"hi">>})
            end
        )
     || {S, Want} <- [
            %% "Failed to read body as a JSON object."
            {400, invalid_request},
            %% "Incorrect API Key."
            {401, auth_failed},
            %% "blocked due to being over plan limits"
            {402, rate_limited},
            {403, auth_failed},
            %% "Could not find the instance."
            {404, invalid_request},
            %% "JSON does not our match schema."
            {422, invalid_request},
            %% "max 100 RPS"
            {429, rate_limited},
            {500, provider_unavailable},
            {409, unknown}
        ]
    ].

unauthorized_maps_auth_failed_test() ->
    {C, _} = cfg(#{}, [?F:resp(401, <<"{\"error\":\"unauthorized\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed}}, ?N:send_push(C, #{to => <<"user-1">>, body => <<"hi">>})
    ).

data_only_is_silent_push_test() ->
    %% APNs background push: aps "includes only the content-available key"; an
    %% empty notification/alert object is not sent.
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"publishId\":\"pub-d\"}">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"user-1">>, data => #{<<"k">> => <<"v">>}}),
    Payload = ?F:body_json(?F:last(P)),
    D = #{<<"k">> => <<"v">>},
    ?assertEqual(
        #{<<"aps">> => #{<<"content-available">> => 1}, <<"data">> => D},
        maps:get(<<"apns">>, Payload)
    ),
    ?assertEqual(#{<<"data">> => D}, maps:get(<<"fcm">>, Payload)),
    ?assertEqual(#{<<"data">> => D}, maps:get(<<"web">>, Payload)).

empty_send_is_apns_only_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"publishId\":\"p\"}">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"u">>}),
    ?assertEqual(
        #{
            <<"apns">> => #{<<"aps">> => #{<<"content-available">> => 1}},
            <<"users">> => [<<"u">>]
        },
        ?F:body_json(?F:last(P))
    ).

instance_id_must_be_dns_label_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{instance_id => Id}, [?F:resp(200, <<"{\"publishId\":\"x\"}">>)]),
            ?assertMatch(
                {error, #{code := invalid_request}},
                ?N:send_push(C, #{to => <<"u">>, title => <<"t">>})
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || Id <- [
            <<"evil.com/x">>,
            <<"a.b">>,
            <<>>,
            <<"-inst">>,
            <<"inst id">>,
            %% test_request_guards.py: whole-string validators reject a
            %% trailing newline.
            <<"inst\n">>,
            binary:copy(<<"a">>, 64)
        ]
    ].

uuid_instance_id_accepted_test() ->
    Id = <<"8f9a6e3c-1b2d-4c5e-9f00-0a1b2c3d4e5f">>,
    {C, P} = cfg(#{instance_id => Id}, [?F:resp(200, <<"{\"publishId\":\"x\"}">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"u">>, title => <<"t">>}),
    ?assertEqual(<<Id/binary, ".pushnotifications.pusher.com">>, ?F:host_of(?F:last(P))).

server_errors_are_provider_unavailable_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<>>)]),
            {error, E} = ?N:send_push(C, #{to => <<"u">>, title => <<"t">>}),
            ?assertMatch(#{code := provider_unavailable}, E),
            ?assertEqual(
                <<"Pusher Beams ", (integer_to_binary(S))/binary>>, maps:get(provider_message, E)
            )
        end)
     || S <- [502, 504]
    ].
