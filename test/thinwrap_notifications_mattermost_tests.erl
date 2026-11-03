-module(thinwrap_notifications_mattermost_tests).

%% Ported from the Python sibling's tests/test_mattermost.py, plus the
%% Mattermost case of test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(WEBHOOK, <<"https://mm.example.com/hooks/xxxxxxx">>).

cfg(Url, Responses) ->
    ?F:config(#{provider => mattermost, webhook_url => Url}, Responses).

send_success_with_channel_override_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"ok">>)]),
    {ok, R} = ?N:send_chat(C, #{
        to => <<"town-square">>,
        body => <<"hello">>,
        passthrough => #{
            body => #{<<"icon_url">> => <<"https://i">>, <<"icon_emoji">> => <<":tada:">>}
        }
    }),
    %% Mattermost returns plain "ok", no id.
    ?assertEqual(
        #{success => true, status => sent, provider_message_id => <<>>, raw => <<"ok">>}, R
    ),
    Req = ?F:last(P),
    ?assertEqual(?WEBHOOK, maps:get(url, Req)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Payload)),
    %% to -> channel override
    ?assertEqual(<<"town-square">>, maps:get(<<"channel">>, Payload)),
    %% passthrough keys ride as given
    ?assertEqual(<<"https://i">>, maps:get(<<"icon_url">>, Payload)),
    ?assertEqual(<<":tada:">>, maps:get(<<"icon_emoji">>, Payload)).

no_channel_when_to_empty_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"ok">>)]),
    {ok, _} = ?N:send_chat(C, #{body => <<"hi">>, passthrough => #{query => #{k => <<"v">>}}}),
    Req = ?F:last(P),
    ?assertEqual(#{<<"text">> => <<"hi">>}, ?F:body_json(Req)),
    %% The passthrough query is not forwarded.
    ?assertEqual(?WEBHOOK, maps:get(url, Req)).

error_auth_failed_on_403_test() ->
    {C, _} = cfg(?WEBHOOK, [?F:resp(403, <<"forbidden">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 403, cause := #{<<"raw">> := <<"forbidden">>}}},
        ?N:send_chat(C, #{body => <<"x">>})
    ).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(?WEBHOOK, [?F:resp(S, Body, #{<<"Retry-After">> => <<"5">>})]),
            {error, E} = ?N:send_chat(C, #{body => <<"x">>}),
            ?assertMatch(#{code := Want, status := S, message := Msg}, E),
            ?assertMatch(#{cause := #{<<"retryAfterSeconds">> := 5}}, E)
        end)
     || {S, Body, Want, Msg} <- [
            {401, <<"x">>, auth_failed, <<"x">>},
            {404, <<>>, auth_failed, <<"Mattermost HTTP 404">>},
            {429, <<>>, rate_limited, <<"Mattermost HTTP 429">>},
            {400, <<"bad">>, invalid_request, <<"bad">>},
            {502, <<>>, provider_unavailable, <<"Mattermost HTTP 502">>},
            {418, <<>>, unknown, <<"Mattermost HTTP 418">>}
        ]
    ].

%% A non-UTF-8 error body must surface as a connector error, never a crash
%% from decoding the response.
non_utf8_error_body_is_connector_error_test() ->
    {C, _} = cfg(?WEBHOOK, [?F:resp(500, <<16#ff, 16#fe, 0, "oops">>)]),
    ?assertMatch(
        {error, #{
            code := provider_unavailable,
            status := 500,
            cause := #{<<"raw">> := <<16#FFFD/utf8, 16#FFFD/utf8, 0, "oops">>}
        }},
        ?N:send_chat(C, #{body => <<"x">>})
    ).

requires_https_webhook_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(Url, [?F:resp(200, <<"ok">>)]),
            ?assertMatch({error, #{code := invalid_request, message := Msg}}, ?N:send_chat(C, #{})),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Url, Msg} <- [
            {<<>>, <<"Mattermost requires `webhook_url` in config (webhook-URL-as-auth).">>},
            {<<"http://mm.example.com/hooks/x">>,
                <<"Mattermost webhook_url must be an https:// URL.">>}
        ]
    ].

%% --- test_passthrough_casing.py ---------------------------------------------

keys_as_given_test() ->
    {C, P} = cfg(<<"https://mm.example.com/hooks/xxx">>, [?F:resp(200, <<"ok">>)]),
    Props = #{<<"card">> => <<"**md**">>, <<"orderId">> => #{<<"lineItem">> => 1}},
    {ok, _} = ?N:send_chat(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{
            body => #{<<"icon_url">> => <<"https://example.com/i.png">>, <<"props">> => Props}
        }
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"https://example.com/i.png">>, maps:get(<<"icon_url">>, Payload)),
    ?assertEqual(Props, maps:get(<<"props">>, Payload)).

%% Each ill-formed sequence becomes U+FFFD exactly as Python's
%% `bytes.decode("utf-8", "replace")` does (expected values from CPython).
replacement_decoding_matches_python_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(?WEBHOOK, [?F:resp(200, In)]),
            {ok, #{raw := Raw}} = ?N:send_chat(C, #{body => <<"x">>}),
            ?assertEqual(binary:decode_hex(Hex), Raw)
        end)
     || {In, Hex} <- [
            {<<16#e2, 16#82>>, <<"efbfbd">>},
            {<<16#e2, 16#82, "A">>, <<"efbfbd41">>},
            {<<16#ed, 16#a0, 16#80, "x">>, <<"efbfbdefbfbdefbfbd78">>},
            {<<16#f0, 16#9f, 16#98>>, <<"efbfbd">>},
            {<<16#f4, 16#90, 16#80, 16#80>>, <<"efbfbdefbfbdefbfbdefbfbd">>},
            {<<16#c0, 16#af>>, <<"efbfbdefbfbd">>},
            {<<"a", 16#e0, 16#80, "b">>, <<"61efbfbdefbfbd62">>},
            {<<"ok", 16#f0, 16#9f, 16#98, 16#80>>, <<"6f6bf09f9880">>},
            {<<16#f1, 16#80, 16#80, 16#c3, 16#a9>>, <<"efbfbdc3a9">>}
        ]
    ].
