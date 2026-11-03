-module(thinwrap_notifications_messagebird_tests).

%% Ported from the Python sibling's tests/test_messagebird.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(maps:merge(#{provider => messagebird, access_key => <<"key">>}, Extra), Responses).

sms() -> #{to => <<"+1">>, body => <<"b">>}.

send_success_test() ->
    {C, P} = cfg(#{from => <<"Acme">>}, [
        ?F:resp(201, <<"{\"id\":\"MB-123\",\"recipients\":{\"totalCount\":1}}">>)
    ]),
    {ok, R} = ?N:send_sms(C, #{to => <<"+15551234567">>, body => <<"hello">>}),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"MB-123">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"rest.messagebird.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/messages">>, ?F:path_of(Req)),
    ?assertEqual(<<"AccessKey key">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(
        #{
            <<"originator">> => <<"Acme">>,
            <<"recipients">> => [<<"+15551234567">>],
            <<"body">> => <<"hello">>
        },
        ?F:body_json(Req)
    ).

passthrough_and_per_send_from_test() ->
    {C, P} = cfg(#{from => <<"Default">>}, [?F:resp(201, <<"{\"id\":\"m\"}">>)]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        from => <<"Override">>,
        passthrough => #{body => #{datacoding => <<"unicode">>, <<"reference">> => <<"R1">>}}
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"Override">>, maps:get(<<"originator">>, Payload)),
    ?assertEqual(<<"unicode">>, maps:get(<<"datacoding">>, Payload)),
    ?assertEqual(<<"R1">>, maps:get(<<"reference">>, Payload)).

requires_originator_test() ->
    {C, P} = cfg(#{}, [?F:resp(201, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    ?assertEqual([], ?F:calls(P)).

error_auth_test() ->
    Body =
        <<
            "{\"errors\":[{\"code\":2,\"description\":\"Request not allowed (incorrect access_key)\","
            "\"parameter\":\"access_key\"}]}"
        >>,
    {C, _} = cfg(#{access_key => <<"bad">>, from => <<"A">>}, [?F:resp(401, Body)]),
    ?assertMatch(
        {error, #{
            code := auth_failed,
            status := 401,
            provider_message := <<"Request not allowed (incorrect access_key)">>
        }},
        ?N:send_sms(C, sms())
    ).

error_server_unavailable_test() ->
    {C, _} = cfg(#{from => <<"A">>}, [?F:resp(503, <<"{}">>)]),
    ?assertMatch(
        {error, #{code := provider_unavailable, provider_message := <<"MessageBird HTTP 503">>}},
        ?N:send_sms(C, sms())
    ).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{from => <<"A">>}, [?F:resp(S, <<"{\"errors\":[]}">>)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_sms(C, sms()))
        end)
     || {S, Want} <- [
            {403, auth_failed}, {429, rate_limited}, {422, invalid_request}, {302, unknown}
        ]
    ].
