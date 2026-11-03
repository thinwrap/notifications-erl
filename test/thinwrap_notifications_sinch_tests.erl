-module(thinwrap_notifications_sinch_tests).

%% Ported from the Python sibling's tests/test_sinch.py, plus the Sinch cases
%% of test_core.py (path escaping) and test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(201, <<"{\"id\":\"b\"}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => sinch,
                service_plan_id => <<"SP">>,
                api_token => <<"T">>,
                from => <<"+1">>
            },
            Extra
        ),
        Responses
    ).

sms() -> #{to => <<"+2">>, body => <<"b">>}.

send_json_bearer_and_array_to_test() ->
    {C, P} = cfg(
        #{service_plan_id => <<"SPID">>, api_token => <<"TOK">>, from => <<"+15550000000">>},
        [?F:resp(201, <<"{\"id\":\"batch-1\",\"to\":[\"+15551111111\"]}">>)]
    ),
    {ok, R} = ?N:send_sms(C, #{
        to => <<"+15551111111">>,
        body => <<"hola">>,
        passthrough => #{body => #{<<"delivery_report">> => <<"full">>}}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"batch-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"us.sms.api.sinch.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/xms/v1/SPID/batches">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer TOK">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(
        #{
            <<"from">> => <<"+15550000000">>,
            %% wrapped as array
            <<"to">> => [<<"+15551111111">>],
            <<"body">> => <<"hola">>,
            %% passthrough keys ride as given (Sinch wire names).
            <<"delivery_report">> => <<"full">>
        },
        ?F:body_json(Req)
    ).

eu_region_host_test() ->
    {C, P} = cfg(#{region => <<"eu">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, sms()),
    ?assertEqual(<<"eu.sms.api.sinch.com">>, ?F:host_of(?F:last(P))).

requires_sender_test() ->
    {C, P} = cfg(#{from => <<>>}, [?F:resp(201, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    ?assertEqual([], ?F:calls(P)).

error_invalid_recipient_via_code_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(400, <<"{\"code\":\"invalid_destination\",\"text\":\"bad number\"}">>)
    ]),
    ?assertMatch(
        {error, #{code := invalid_recipient, provider_message := <<"bad number">>}},
        ?N:send_sms(C, sms())
    ).

error_auth_failed_test() ->
    {C, _} = cfg(#{api_token => <<"bad">>}, [?F:resp(401, <<"{\"text\":\"unauthorized\"}">>)]),
    ?assertMatch({error, #{code := auth_failed}}, ?N:send_sms(C, sms())).

error_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, Body)]),
            ?assertMatch({error, #{code := Want, provider_message := Msg}}, ?N:send_sms(C, sms()))
        end)
     || {S, Body, Want, Msg} <- [
            {403, <<"{\"code\":\"invalid_recipient\"}">>, auth_failed, <<"Sinch HTTP 403">>},
            {429, <<>>, rate_limited, <<"Sinch HTTP 429">>},
            {503, <<>>, provider_unavailable, <<"Sinch HTTP 503">>},
            {400, <<"{\"code\":\"invalid_recipient\"}">>, invalid_recipient, <<"Sinch HTTP 400">>},
            {400, <<"{\"code\":\"syntax_invalid_json\",\"text\":\"t\"}">>, invalid_request,
                <<"t">>},
            {302, <<>>, unknown, <<"Sinch HTTP 302">>}
        ]
    ].

documented_regions_test_() ->
    %% SMS API reference: https://{region}.sms.api.sinch.com for us/eu/au/br/ca.
    [
        ?_test(begin
            {C, P} = cfg(#{region => Region}, [?OK]),
            {ok, _} = ?N:send_sms(C, sms()),
            ?assertEqual(<<Region/binary, ".sms.api.sinch.com">>, ?F:host_of(?F:last(P)))
        end)
     || Region <- [<<"us">>, <<"eu">>, <<"au">>, <<"br">>, <<"ca">>]
    ].

unknown_region_rejected_before_sending_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{region => Region}, [?OK]),
            ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
            ?assertEqual([], ?F:calls(P))
        end)
     || Region <- [<<"evil.com/">>, <<"xx">>, <<"EU">>]
    ].

unknown_region_message_test() ->
    {C, _} = cfg(#{region => <<"xx">>}, [?OK]),
    ?assertMatch(
        {error, #{message := <<"Unknown Sinch region: xx (expected one of us, eu, au, br, ca)">>}},
        ?N:send_sms(C, sms())
    ).

service_plan_id_path_segment_escaped_test() ->
    {C, P} = cfg(#{service_plan_id => <<"sp/../x?y">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, sms()),
    ?assertEqual(<<"/xms/v1/sp%2F..%2Fx%3Fy/batches">>, ?F:path_of(?F:last(P))).

passthrough_query_is_forwarded_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{passthrough => #{query => #{<<"trace">> => <<"1">>}}}),
    ?assertEqual(<<"1">>, ?F:qget(?F:last(P), <<"trace">>)).

keys_as_given_test() ->
    {C, P} = cfg(#{from => <<"+15550000000">>}, [?F:resp(201, <<"{\"id\":\"batch-1\"}">>)]),
    Params = #{<<"firstName">> => #{<<"+15551234567">> => <<"Ada">>, <<"default">> => <<"there">>}},
    {ok, _} = ?N:send_sms(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{body => #{<<"delivery_report">> => <<"full">>, parameters => Params}}
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"full">>, maps:get(<<"delivery_report">>, Payload)),
    ?assertEqual(Params, maps:get(<<"parameters">>, Payload)).
