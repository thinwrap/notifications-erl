-module(thinwrap_notifications_slack_tests).

%% Ported from the Python sibling's tests/test_slack.py, plus the Slack cases
%% of test_passthrough_casing.py and test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(WEBHOOK, <<"https://hooks.slack.com/services/T00/B00/XXXX">>).

cfg(Url, Responses) ->
    ?F:config(#{provider => slack, webhook_url => Url}, Responses).

send_success_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"ok">>)]),
    {ok, R} = ?N:send_chat(C, #{
        %% `to` is ignored — the webhook URL targets the channel.
        to => <<"#ignored">>,
        body => <<"hello">>,
        passthrough => #{body => #{<<"icon_emoji">> => <<":tada:">>, thread_ts => <<"1.2">>}}
    }),
    %% Slack returns plain "ok", no id.
    ?assertEqual(
        #{success => true, status => sent, provider_message_id => <<>>, raw => <<"ok">>}, R
    ),
    Req = ?F:last(P),
    ?assertEqual(?WEBHOOK, maps:get(url, Req)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Payload)),
    ?assertNot(maps:is_key(<<"channel">>, Payload)),
    ?assertNot(maps:is_key(<<"to">>, Payload)),
    %% passthrough keys ride as given
    ?assertEqual(<<":tada:">>, maps:get(<<"icon_emoji">>, Payload)),
    ?assertEqual(<<"1.2">>, maps:get(<<"thread_ts">>, Payload)).

passthrough_query_is_not_forwarded_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"ok">>)]),
    {ok, _} = ?N:send_chat(C, #{body => <<"x">>, passthrough => #{query => #{k => <<"v">>}}}),
    ?assertEqual(?WEBHOOK, maps:get(url, ?F:last(P))).

error_auth_failed_on_404_test() ->
    {C, _} = cfg(?WEBHOOK, [?F:resp(404, <<"no_service">>)]),
    ?assertMatch(
        {error, #{
            code := auth_failed,
            status := 404,
            provider_message := <<"no_service">>,
            cause := #{<<"raw">> := <<"no_service">>}
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
            {401, <<"invalid_token">>, auth_failed, <<"invalid_token">>},
            {403, <<"action_prohibited">>, auth_failed, <<"action_prohibited">>},
            {429, <<>>, rate_limited, <<"Slack HTTP 429">>},
            {400, <<"no_text">>, invalid_request, <<"no_text">>},
            {503, <<>>, provider_unavailable, <<"Slack HTTP 503">>},
            {302, <<>>, unknown, <<"Slack HTTP 302">>}
        ]
    ].

retry_after_header_surfaces_test() ->
    {C, _} = cfg(?WEBHOOK, [?F:resp(429, <<"rate_limited">>, #{<<"Retry-After">> => <<"30">>})]),
    {error, #{cause := Cause}} = ?N:send_chat(C, #{body => <<"x">>}),
    ?assertEqual(
        #{
            <<"raw">> => <<"rate_limited">>,
            <<"retryAfter">> => <<"30">>,
            <<"retryAfterSeconds">> => 30
        },
        Cause
    ).

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

requires_webhook_test() ->
    {C, P} = cfg(<<>>, [?F:resp(200, <<"ok">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_request,
            message := <<"Slack requires `webhook_url` in config (webhook-URL-as-auth).">>
        }},
        ?N:send_chat(C, #{body => <<"x">>})
    ),
    ?assertEqual([], ?F:calls(P)).

http_webhook_rejected_before_sending_test() ->
    {C, P} = cfg(<<"http://hooks.slack.com/services/T/B/SECRET">>, [?F:resp(200, <<"ok">>)]),
    {error, E} = ?N:send_chat(C, #{body => <<"x">>}),
    ?assertMatch(
        #{code := invalid_request, message := <<"Slack webhook_url must be an https:// URL.">>}, E
    ),
    ?assertEqual([], ?F:calls(P)),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [E])), <<"SECRET">>)).

webhook_fun_is_resolved_test() ->
    {C, P} = cfg(fun() -> ?WEBHOOK end, [?F:resp(200, <<"ok">>)]),
    {ok, _} = ?N:send_chat(C, #{body => <<"x">>}),
    ?assertEqual(?WEBHOOK, maps:get(url, ?F:last(P))).

%% --- test_passthrough_casing.py ---------------------------------------------

keys_as_given_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"ok">>)]),
    Meta = #{
        <<"event_type">> => <<"order">>, <<"event_payload">> => #{<<"orderId">> => <<"o-1">>}
    },
    {ok, _} = ?N:send_chat(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{
            body => #{<<"thread_ts">> => <<"1700000000.000100">>, <<"metadata">> => Meta}
        }
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"1700000000.000100">>, maps:get(<<"thread_ts">>, Payload)),
    ?assertEqual(Meta, maps:get(<<"metadata">>, Payload)).

%% --- test_request_guards.py -------------------------------------------------

assert_invalid_request(Result, P, Secret) ->
    ?assertMatch({error, #{code := invalid_request}}, Result),
    ?assertEqual([], ?F:calls(P)),
    {error, E} = Result,
    ?assertEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [E])), Secret)).

url_with_whitespace_is_invalid_request_test() ->
    {C, P} = cfg(<<"https://hooks.slack.com/services/T0 0/B/X">>, [?F:resp(200, <<"ok">>)]),
    assert_invalid_request(?N:send_chat(C, #{body => <<"x">>}), P, <<"T0 0">>).

bad_port_or_non_ascii_url_rejected_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(Url, [?F:resp(200, <<"ok">>)]),
            assert_invalid_request(?N:send_chat(C, #{body => <<"x">>}), P, <<"services/T/B">>)
        end)
     || Url <- [
            <<"https://hooks.slack.com:abc/services/T/B/X">>,
            <<"https://hooks.slack.com:99999/services/T/B/X">>,
            <<"https://hooks.slack.com/services/T/B/Xé"/utf8>>
        ]
    ].
