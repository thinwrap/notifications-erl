-module(thinwrap_notifications_discord_tests).

%% Ported from the Python sibling's tests/test_discord.py, plus the Discord
%% case of test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(WEBHOOK, <<"https://discord.com/api/webhooks/1/abcdef">>).

cfg(Url, Responses) ->
    ?F:config(#{provider => discord, webhook_url => Url}, Responses).

send_success_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"{\"id\":\"111222333\",\"channel_id\":\"444\"}">>)]),
    {ok, R} = ?N:send_chat(C, #{
        to => <<"#ignored">>,
        body => <<"hi there">>,
        passthrough => #{
            body => #{<<"avatar_url">> => <<"https://img">>, <<"thread_name">> => <<"topic">>}
        }
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"111222333">>}, R),
    ?assertEqual(#{<<"id">> => <<"111222333">>, <<"channel_id">> => <<"444">>}, maps:get(raw, R)),
    Req = ?F:last(P),
    %% ?wait=true is appended by default so Discord returns the created message.
    ?assertEqual(<<?WEBHOOK/binary, "?wait=true">>, maps:get(url, Req)),
    ?assertEqual(<<"true">>, ?F:qget(Req, <<"wait">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"hi there">>, maps:get(<<"content">>, Payload)),
    ?assertNot(maps:is_key(<<"to">>, Payload)),
    %% passthrough keys ride as given
    ?assertEqual(<<"https://img">>, maps:get(<<"avatar_url">>, Payload)),
    ?assertEqual(<<"topic">>, maps:get(<<"thread_name">>, Payload)).

passthrough_query_overrides_wait_and_adds_thread_test() ->
    {C, P} = cfg(<<?WEBHOOK/binary, "?x=1">>, [?F:resp(204, <<>>)]),
    {ok, R} = ?N:send_chat(C, #{
        body => <<"x">>, passthrough => #{query => #{wait => false, thread_id => <<"9">>}}
    }),
    %% 204 No Content / an empty body: no id, raw null.
    ?assertMatch(#{provider_message_id := <<>>, raw := null}, R),
    ?assertEqual(
        <<?WEBHOOK/binary, "?x=1&wait=false&thread_id=9">>, maps:get(url, ?F:last(P))
    ).

error_rate_limited_test() ->
    {C, _} = cfg(?WEBHOOK, [
        ?F:resp(
            429,
            <<"{\"message\":\"You are being rate limited.\",\"retry_after\":1.5}">>,
            #{<<"Retry-After">> => <<"2">>}
        )
    ]),
    {error, E} = ?N:send_chat(C, #{body => <<"x">>}),
    ?assertMatch(
        #{
            code := rate_limited,
            status := 429,
            provider_message := <<"You are being rate limited.">>,
            cause := #{<<"retryAfter">> := <<"2">>, <<"retryAfterSeconds">> := 2}
        },
        E
    ).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(?WEBHOOK, [?F:resp(S, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := S, message := Msg}},
                ?N:send_chat(C, #{body => <<"x">>})
            )
        end)
     || {S, Body, Want, Msg} <- [
            {401, <<"{\"message\":\"Invalid Webhook Token\"}">>, auth_failed,
                <<"Invalid Webhook Token">>},
            {403, <<>>, auth_failed, <<"Discord HTTP 403">>},
            {404, <<"{\"message\":\"Unknown Webhook\",\"code\":10015}">>, auth_failed,
                <<"Unknown Webhook">>},
            {400, <<"{\"message\":\"Cannot send an empty message\"}">>, invalid_request,
                <<"Cannot send an empty message">>},
            {500, <<"<html>">>, provider_unavailable, <<"Discord HTTP 500">>},
            {409, <<"{\"message\":7}">>, unknown, <<"Discord HTTP 409">>}
        ]
    ].

requires_https_webhook_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(Url, [?F:resp(200, <<"{}">>)]),
            ?assertMatch({error, #{code := invalid_request, message := Msg}}, ?N:send_chat(C, #{})),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Url, Msg} <- [
            {<<>>, <<"Discord requires `webhook_url` in config (webhook-URL-as-auth).">>},
            {<<"http://discord.com/api/webhooks/1/x">>,
                <<"Discord webhook_url must be an https:// URL.">>}
        ]
    ].

%% --- test_passthrough_casing.py ---------------------------------------------

keys_as_given_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"{\"id\":\"1\"}">>)]),
    Mentions = #{<<"parse">> => [], <<"replied_user">> => false},
    {ok, _} = ?N:send_chat(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{
            body => #{<<"thread_name">> => <<"Build">>, <<"allowed_mentions">> => Mentions}
        }
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"Build">>, maps:get(<<"thread_name">>, Payload)),
    ?assertEqual(Mentions, maps:get(<<"allowed_mentions">>, Payload)).
