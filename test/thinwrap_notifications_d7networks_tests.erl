-module(thinwrap_notifications_d7networks_tests).

%% Ported from the Python sibling's tests/test_d7networks.py, plus the D7
%% case of test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(200, <<"{\"request_id\":\"r\"}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(#{provider => d7networks, api_token => <<"tok">>, from => <<"A">>}, Extra),
        Responses
    ).

sms() -> #{to => <<"+1">>, body => <<"b">>}.

send_success_test() ->
    {C, P} = cfg(#{from => <<"SignOTP">>}, [
        ?F:resp(200, <<"{\"request_id\":\"REQ-1\",\"request_count\":1,\"total_credits\":0.4}">>)
    ]),
    {ok, R} = ?N:send_sms(C, #{to => <<"+15551234567">>, body => <<"your code">>}),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"REQ-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"api.d7networks.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/messages/v1/send">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer tok">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Accept">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(
        [
            #{
                <<"channel">> => <<"sms">>,
                <<"recipients">> => [<<"+15551234567">>],
                <<"content">> => <<"your code">>,
                <<"msg_type">> => <<"text">>
            }
        ],
        maps:get(<<"messages">>, Payload)
    ),
    ?assertEqual(#{<<"originator">> => <<"SignOTP">>}, maps:get(<<"message_globals">>, Payload)).

snake_case_passthrough_deep_merges_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{
            body => #{
                message_globals => #{
                    schedule_time => <<"2026-01-01T00:00:00">>, <<"report_url">> => <<"https://cb">>
                }
            }
        }
    }),
    %% Passthrough keys are D7's own names; they deep-merge into the
    %% connector-set message_globals.
    ?assertEqual(
        #{
            <<"originator">> => <<"A">>,
            <<"schedule_time">> => <<"2026-01-01T00:00:00">>,
            <<"report_url">> => <<"https://cb">>
        },
        maps:get(<<"message_globals">>, ?F:body_json(?F:last(P)))
    ).

nested_passthrough_keys_verbatim_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{body => #{<<"message_globals">> => #{<<"reportUrl">> => <<"https://cb">>}}}
    }),
    ?assertEqual(
        <<"https://cb">>,
        maps:get(<<"reportUrl">>, maps:get(<<"message_globals">>, ?F:body_json(?F:last(P))))
    ).

requires_originator_test() ->
    {C, P} = cfg(#{from => <<>>}, [?F:resp(200, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    ?assertEqual([], ?F:calls(P)).

error_auth_test() ->
    {C, _} = cfg(#{api_token => <<"bad">>}, [
        ?F:resp(
            401,
            <<"{\"code\":\"token_invalid\",\"detail\":\"Given token not valid for any token type\"}">>
        )
    ]),
    ?assertMatch(
        {error, #{
            code := auth_failed,
            status := 401,
            provider_message := <<"Given token not valid for any token type">>
        }},
        ?N:send_sms(C, sms())
    ).

error_invalid_request_test() ->
    {C, _} = cfg(#{}, [?F:resp(400, <<"{\"code\":\"invalid_request\",\"detail\":\"bad body\"}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())).

error_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, Body)]),
            ?assertMatch({error, #{code := Want, provider_message := Msg}}, ?N:send_sms(C, sms()))
        end)
     || {S, Body, Want, Msg} <- [
            {403, <<"{\"code\":\"forbidden\"}">>, auth_failed,
                <<"D7 Networks HTTP 403 forbidden">>},
            {429, <<>>, rate_limited, <<"D7 Networks HTTP 429">>},
            {502, <<>>, provider_unavailable, <<"D7 Networks HTTP 502">>},
            {302, <<>>, unknown, <<"D7 Networks HTTP 302">>}
        ]
    ].

keys_as_given_test() ->
    {C, P} = cfg(#{from => <<"Acme">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{passthrough => #{body => #{camelKey => 1}}}),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(1, maps:get(<<"camelKey">>, Payload)),
    ?assertNot(maps:is_key(<<"camel_key">>, Payload)).
