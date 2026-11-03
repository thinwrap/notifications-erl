-module(thinwrap_notifications_rocketchat_tests).

%% Ported from the Python sibling's tests/test_rocketchat.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(WEBHOOK, <<"https://chat.acme.io/hooks/abc123/def456">>).

cfg(Url, Responses) ->
    ?F:config(#{provider => 'rocket-chat', webhook_url => Url}, Responses).

send_with_channel_override_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"{\"success\":true}">>)]),
    {ok, R} = ?N:send_chat(C, #{to => <<"#general">>, body => <<"yo">>}),
    ?assertEqual(
        #{
            success => true,
            status => sent,
            provider_message_id => <<>>,
            raw => #{<<"success">> => true}
        },
        R
    ),
    Req = ?F:last(P),
    ?assertEqual(?WEBHOOK, maps:get(url, Req)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    %% `to` translates to the wire `channel` field.
    ?assertEqual(#{<<"text">> => <<"yo">>, <<"channel">> => <<"#general">>}, ?F:body_json(Req)).

send_without_channel_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"{\"success\":true}">>)]),
    {ok, _} = ?N:send_chat(C, #{body => <<"hi">>, passthrough => #{query => #{k => <<"v">>}}}),
    Req = ?F:last(P),
    ?assertEqual(#{<<"text">> => <<"hi">>}, ?F:body_json(Req)),
    %% The passthrough query is not forwarded.
    ?assertEqual(?WEBHOOK, maps:get(url, Req)).

passthrough_verbatim_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"{\"success\":true}">>)]),
    Atts = [#{<<"author_name">> => <<"bot">>, <<"image_url">> => <<"u">>}],
    {ok, _} = ?N:send_chat(C, #{
        body => <<"hi">>, passthrough => #{body => #{<<"attachments">> => Atts, alias => <<"Bot">>}}
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(Atts, maps:get(<<"attachments">>, Payload)),
    ?assertEqual(<<"Bot">>, maps:get(<<"alias">>, Payload)).

non_json_success_empty_object_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(?WEBHOOK, [?F:resp(200, Body)]),
            ?assertMatch({ok, #{raw := Raw}} when Raw =:= #{}, ?N:send_chat(C, #{body => <<"hi">>}))
        end)
     || Body <- [<<>>, <<"ok">>, <<"null">>]
    ].

requires_webhook_test() ->
    {C, P} = cfg(<<>>, [?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_request,
            message := <<"Rocket.Chat requires `webhookUrl` in config (webhook-URL-as-auth).">>
        }},
        ?N:send_chat(C, #{body => <<"x">>})
    ),
    ?assertEqual([], ?F:calls(P)).

error_auth_test() ->
    {C, _} = cfg(?WEBHOOK, [
        ?F:resp(401, <<"{\"success\":false,\"error\":\"invalid webhook token\"}">>)
    ]),
    ?assertMatch(
        {error, #{
            code := auth_failed, status := 401, provider_message := <<"invalid webhook token">>
        }},
        ?N:send_chat(C, #{body => <<"x">>})
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
            {403, <<"{\"message\":\"forbidden\"}">>, auth_failed, <<"forbidden">>},
            {404, <<>>, auth_failed, <<"Rocket.Chat HTTP 404">>},
            {429, <<"{\"error\":\"\",\"message\":\"slow\"}">>, rate_limited, <<"slow">>},
            {400, <<"{\"error\":\"bad\",\"message\":\"m\"}">>, invalid_request, <<"bad">>},
            {500, <<>>, provider_unavailable, <<"Rocket.Chat HTTP 500">>},
            {405, <<>>, unknown, <<"Rocket.Chat HTTP 405">>}
        ]
    ].

%% The webhook URL embeds the integration token; an injected transport may
%% accept http://, so the connector itself refuses it.
http_webhook_rejected_before_sending_test() ->
    {C, P} = cfg(<<"http://chat.acme.io/hooks/abc/def">>, [?F:resp(200, <<"{\"success\":true}">>)]),
    {error, E} = ?N:send_chat(C, #{body => <<"x">>}),
    ?assertMatch(
        #{
            code := invalid_request,
            message := <<"Rocket.Chat webhook_url must be an https:// URL.">>
        },
        E
    ),
    ?assertEqual([], ?F:calls(P)),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [E])), <<"abc/def">>)).
