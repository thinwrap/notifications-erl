-module(thinwrap_notifications_googlechat_tests).

%% Ported from the Python sibling's tests/test_googlechat.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(WEBHOOK,
    <<"https://chat.googleapis.com/v1/spaces/AAAA/messages?key=secret-key&token=secret-token">>
).

cfg(Url, Responses) ->
    ?F:config(#{provider => 'google-chat', webhook_url => Url}, Responses).

send_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"{\"name\":\"spaces/AAAA/messages/BBBB.CCCC\"}">>)]),
    {ok, R} = ?N:send_chat(C, #{body => <<"hey space">>, to => <<"ignored">>}),
    ?assertMatch(
        #{
            success := true,
            status := sent,
            provider_message_id := <<"spaces/AAAA/messages/BBBB.CCCC">>,
            raw := #{<<"name">> := _}
        },
        R
    ),
    Req = ?F:last(P),
    %% The ?key=&token= credential query params are preserved.
    ?assertEqual(<<"secret-key">>, ?F:qget(Req, <<"key">>)),
    ?assertEqual(<<"secret-token">>, ?F:qget(Req, <<"token">>)),
    ?assertEqual(<<"application/json; charset=UTF-8">>, ?F:header(Req, <<"Content-Type">>)),
    ?assertEqual(#{<<"text">> => <<"hey space">>}, ?F:body_json(Req)).

camelcase_passthrough_verbatim_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"{\"name\":\"spaces/A/messages/B\"}">>)]),
    {ok, _} = ?N:send_chat(C, #{
        body => <<"hi">>,
        passthrough => #{
            body => #{
                <<"cardsV2">> => [#{<<"cardId">> => <<"c1">>}], <<"fallbackText">> => <<"fb">>
            },
            query => #{messageReplyOption => <<"REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD">>}
        }
    }),
    Req = ?F:last(P),
    Payload = ?F:body_json(Req),
    %% camelCase keys forwarded verbatim (no transform).
    ?assertEqual([#{<<"cardId">> => <<"c1">>}], maps:get(<<"cardsV2">>, Payload)),
    ?assertEqual(<<"fb">>, maps:get(<<"fallbackText">>, Payload)),
    %% The passthrough query is appended after the credential params.
    ?assertEqual(
        <<?WEBHOOK/binary, "&messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD">>,
        maps:get(url, Req)
    ).

requires_webhook_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(Url, [?F:resp(200, <<"{}">>)]),
            ?assertMatch({error, #{code := invalid_request, message := Msg}}, ?N:send_chat(C, #{})),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Url, Msg} <- [
            {<<>>, <<"Google Chat requires `webhookUrl` in config (webhook-URL-as-auth).">>},
            {<<"http://chat.googleapis.com/v1/spaces/A/messages?key=k">>,
                <<"Google Chat webhook_url must be an https:// URL.">>}
        ]
    ].

error_auth_test() ->
    {C, _} = cfg(?WEBHOOK, [
        ?F:resp(403, <<"{\"error\":{\"code\":403,\"message\":\"permission denied\"}}">>)
    ]),
    {error, E} = ?N:send_chat(C, #{body => <<"x">>}),
    ?assertMatch(
        #{code := auth_failed, status := 403, provider_message := <<"permission denied">>}, E
    ),
    %% The webhook's credential query never rides in the error.
    ?assertEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [E])), <<"secret">>)).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(?WEBHOOK, [?F:resp(S, Body, #{<<"Retry-After">> => <<"4">>})]),
            {error, E} = ?N:send_chat(C, #{body => <<"x">>}),
            ?assertMatch(
                #{
                    code := Want,
                    status := S,
                    message := Msg,
                    cause := #{<<"retryAfterSeconds">> := 4}
                },
                E
            )
        end)
     || {S, Body, Want, Msg} <- [
            {401, <<>>, auth_failed, <<"Google Chat HTTP 401">>},
            {404, <<"{\"error\":{\"message\":\"not found\"}}">>, auth_failed, <<"not found">>},
            {429, <<"{\"error\":{\"message\":\"quota\"}}">>, rate_limited, <<"quota">>},
            {400, <<"{\"error\":\"flat\"}">>, invalid_request, <<"Google Chat HTTP 400">>},
            {503, <<>>, provider_unavailable, <<"Google Chat HTTP 503">>},
            {409, <<>>, unknown, <<"Google Chat HTTP 409">>}
        ]
    ].

non_json_success_has_empty_id_test() ->
    {C, _} = cfg(?WEBHOOK, [?F:resp(200, <<"ok">>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>, raw := null}}, ?N:send_chat(C, #{})).
