-module(thinwrap_notifications_plivo_tests).

%% Ported from the Python sibling's tests/test_plivo.py, plus the Plivo cases
%% of test_core.py (path escaping) and test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(202, <<"{\"message_uuid\":[\"u\"]}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(#{provider => plivo, auth_id => <<"A">>, auth_token => <<"T">>}, Extra),
        Responses
    ).

sms() -> #{to => <<"+1">>, body => <<"b">>}.

send_json_basic_auth_and_passthrough_test() ->
    {C, P} = cfg(
        #{auth_id => <<"MAID">>, auth_token => <<"TOK">>, from => <<"+15550000000">>},
        [?F:resp(202, <<"{\"message_uuid\":[\"uuid-1\",\"uuid-2\"],\"api_id\":\"api-9\"}">>)]
    ),
    {ok, R} = ?N:send_sms(C, #{
        to => <<"+15551111111">>,
        body => <<"hey">>,
        passthrough => #{body => #{<<"dlt_template_id">> => <<"T1">>}}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"uuid-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"api.plivo.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v1/Account/MAID/Message/">>, ?F:path_of(Req)),
    ?assertEqual(
        <<"Basic ", (base64:encode(<<"MAID:TOK">>))/binary>>, ?F:header(Req, <<"Authorization">>)
    ),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    ?assertEqual(
        #{
            <<"dst">> => <<"+15551111111">>,
            <<"text">> => <<"hey">>,
            <<"src">> => <<"+15550000000">>,
            %% passthrough keys ride as given (Plivo wire names).
            <<"dlt_template_id">> => <<"T1">>
        },
        ?F:body_json(Req)
    ).

powerpack_passthrough_no_sender_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{passthrough => #{body => #{powerpack_uuid => <<"pp-1">>}}}),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"pp-1">>, maps:get(<<"powerpack_uuid">>, Payload)),
    ?assertNot(maps:is_key(<<"src">>, Payload)).

requires_sender_test() ->
    {C, P} = cfg(#{}, [?F:resp(202, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    %% A null powerpack_uuid is no powerpack (the sibling's `is not None`).
    ?assertMatch(
        {error, #{code := invalid_request}},
        ?N:send_sms(C, (sms())#{passthrough => #{body => #{<<"powerpack_uuid">> => null}}})
    ),
    ?assertEqual([], ?F:calls(P)).

error_auth_failed_test() ->
    {C, _} = cfg(#{auth_token => <<"bad">>, from => <<"+1">>}, [
        ?F:resp(401, <<"{\"error\":\"invalid credentials\"}">>)
    ]),
    ?assertMatch(
        {error, #{
            code := auth_failed, status := 401, provider_message := <<"invalid credentials">>
        }},
        ?N:send_sms(C, sms())
    ).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{from => <<"+1">>}, [?F:resp(S, <<>>)]),
            {error, E} = ?N:send_sms(C, sms()),
            ?assertMatch(#{code := Want}, E),
            ?assertEqual(
                <<"Plivo HTTP ", (integer_to_binary(S))/binary>>, maps:get(provider_message, E)
            )
        end)
     || {S, Want} <- [
            {403, auth_failed},
            {429, rate_limited},
            {500, provider_unavailable},
            {400, invalid_request},
            {302, unknown}
        ]
    ].

no_message_uuid_is_empty_id_test() ->
    {C, _} = cfg(#{from => <<"+1">>}, [?F:resp(202, <<"{\"message_uuid\":[]}">>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>}}, ?N:send_sms(C, sms())).

auth_id_path_segment_escaped_test() ->
    {C, P} = cfg(#{auth_id => <<"MA/x?">>, from => <<"+1">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, sms()),
    ?assertEqual(<<"/v1/Account/MA%2Fx%3F/Message/">>, ?F:path_of(?F:last(P))).

keys_as_given_test() ->
    {C, P} = cfg(#{from => <<"+15550000000">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{body => #{<<"dlt_template_id">> => <<"tpl-1">>, <<"camelKey">> => 1}}
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"tpl-1">>, maps:get(<<"dlt_template_id">>, Payload)),
    ?assertEqual(1, maps:get(<<"camelKey">>, Payload)).
