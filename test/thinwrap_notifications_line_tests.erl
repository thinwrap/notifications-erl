-module(thinwrap_notifications_line_tests).

%% Ported from the Python sibling's tests/test_line.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Responses) ->
    ?F:config(#{provider => line, channel_access_token => <<"TOKEN">>}, Responses).

send_success_test() ->
    {C, P} = cfg([
        ?F:resp(
            200, <<"{\"sentMessages\":[{\"id\":\"461230966842064897\",\"quoteToken\":\"q\"}]}">>
        )
    ]),
    {ok, R} = ?N:send_chat(C, #{
        to => <<"U1234567890">>,
        body => <<"hello">>,
        passthrough => #{body => #{<<"notificationDisabled">> => true}, query => #{k => <<"v">>}}
    }),
    ?assertMatch(
        #{success := true, status := sent, provider_message_id := <<"461230966842064897">>}, R
    ),
    Req = ?F:last(P),
    ?assertEqual(<<"api.line.me">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v2/bot/message/push">>, ?F:path_of(Req)),
    %% LINE push reads no query string, so the passthrough query is dropped.
    ?assertEqual(<<"https://api.line.me/v2/bot/message/push">>, maps:get(url, Req)),
    ?assertEqual(<<"Bearer TOKEN">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"U1234567890">>, maps:get(<<"to">>, Payload)),
    ?assertEqual(
        [#{<<"type">> => <<"text">>, <<"text">> => <<"hello">>}], maps:get(<<"messages">>, Payload)
    ),
    %% camelCase forwarded verbatim — NO casing transform for LINE
    ?assertEqual(true, maps:get(<<"notificationDisabled">>, Payload)).

passthrough_messages_replace_the_synthesized_one_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"sentMessages\":[]}">>)]),
    Sticker = [#{<<"type">> => <<"sticker">>, <<"packageId">> => <<"446">>}],
    {ok, R} = ?N:send_chat(C, #{
        to => <<"U1">>, body => <<"x">>, passthrough => #{body => #{messages => Sticker}}
    }),
    ?assertEqual(Sticker, maps:get(<<"messages">>, ?F:body_json(?F:last(P)))),
    ?assertMatch(#{provider_message_id := <<>>}, R).

requires_to_test() ->
    {C, P} = cfg([?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_request,
            message := <<"LINE requires `to` (userId / groupId / roomId).">>
        }},
        ?N:send_chat(C, #{body => <<"x">>})
    ),
    ?assertEqual([], ?F:calls(P)).

error_invalid_recipient_test() ->
    {C, _} = cfg([?F:resp(400, <<"{\"message\":\"Invalid userId\"}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient, status := 400, provider_message := <<"Invalid userId">>
        }},
        ?N:send_chat(C, #{to => <<"Ubad">>, body => <<"x">>})
    ).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(S, Body, #{<<"Retry-After">> => <<"9">>})]),
            {error, E} = ?N:send_chat(C, #{to => <<"U1">>, body => <<"x">>}),
            ?assertMatch(
                #{
                    code := Want,
                    status := S,
                    message := Msg,
                    cause := #{<<"retryAfterSeconds">> := 9}
                },
                E
            )
        end)
     || {S, Body, Want, Msg} <- [
            {401, <<"{\"message\":\"Authentication failed\"}">>, auth_failed,
                <<"Authentication failed">>},
            {403, <<>>, auth_failed, <<"LINE HTTP 403">>},
            {429, <<"{\"message\":\"Too Many Requests\"}">>, rate_limited, <<"Too Many Requests">>},
            {400, <<"{\"message\":\"The user ID is NOT FOUND\"}">>, invalid_recipient,
                <<"The user ID is NOT FOUND">>},
            {400, <<"{\"message\":\"Bad user id\"}">>, invalid_recipient, <<"Bad user id">>},
            {400, <<"{\"message\":\"The request body has 1 error(s)\"}">>, invalid_request,
                <<"The request body has 1 error(s)">>},
            {400, <<>>, invalid_request, <<"LINE HTTP 400">>},
            {500, <<>>, provider_unavailable, <<"LINE HTTP 500">>},
            {404, <<"{\"message\":\"Not found\"}">>, unknown, <<"Not found">>}
        ]
    ].
