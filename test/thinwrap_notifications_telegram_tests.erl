-module(thinwrap_notifications_telegram_tests).

%% Ported from the Python sibling's tests/test_telegram.py, plus the Telegram
%% cases of test_core.py (transport leak, raised non-2xx, path escaping),
%% test_passthrough_casing.py and test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-behaviour(thinwrap_notifications_transport).
-export([request/2]).

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

%% Mimics a client whose error embeds the full request URL — the leak vector
%% the transport-error normalization guards against.
request(#{url := Url}, leak) ->
    {error, {failed_connect, [{to_address, Url}]}};
request(_Req, dead) ->
    {error, econnreset}.

cfg(Token, Responses) ->
    ?F:config(#{provider => telegram, bot_token => Token}, Responses).

send_success_test() ->
    {C, P} = cfg(<<"123456:ABC-DEF">>, [
        ?F:resp(200, <<"{\"ok\":true,\"result\":{\"message_id\":12345,\"chat\":{\"id\":99}}}">>)
    ]),
    {ok, R} = ?N:send_chat(C, #{
        to => <<"@mychannel">>,
        body => <<"hello">>,
        passthrough => #{
            body => #{<<"parse_mode">> => <<"MarkdownV2">>, <<"disable_notification">> => true}
        }
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"12345">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"api.telegram.org">>, ?F:host_of(Req)),
    ?assertEqual(<<"/bot123456:ABC-DEF/sendMessage">>, ?F:path_of(Req)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"@mychannel">>, maps:get(<<"chat_id">>, Payload)),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Payload)),
    %% passthrough keys ride as given
    ?assertEqual(<<"MarkdownV2">>, maps:get(<<"parse_mode">>, Payload)),
    ?assertEqual(true, maps:get(<<"disable_notification">>, Payload)).

requires_to_test() ->
    {C, P} = cfg(<<"t">>, [?F:resp(200, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_chat(C, #{body => <<"x">>})),
    ?assertEqual([], ?F:calls(P)).

error_invalid_recipient_test() ->
    {C, _} = cfg(<<"t">>, [
        ?F:resp(
            400,
            <<"{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: chat not found\"}">>
        )
    ]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient,
            status := 400,
            provider_message := <<"Bad Request: chat not found">>
        }},
        ?N:send_chat(C, #{to => <<"@nope">>, body => <<"x">>})
    ).

%% HTTP 200 with ok:false + error_code drives the mapper via the body code.
%% Bot API server: USER_IS_BLOCKED -> 403 "bot was blocked by the user" — the
%% recipient's state, not the token's.
soft_rejection_200_ok_false_test() ->
    {C, _} = cfg(<<"t">>, [
        ?F:resp(
            200,
            <<"{\"ok\":false,\"error_code\":403,\"description\":\"Forbidden: bot was blocked by the user\"}">>
        )
    ]),
    ?assertMatch(
        {error, #{code := invalid_recipient, status := 403}},
        ?N:send_chat(C, #{to => <<"123">>, body => <<"x">>})
    ).

soft_rejection_status_fallbacks_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(<<"t">>, [?F:resp(200, Body)]),
            {error, E} = ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>}),
            ?assertMatch(#{status := Status, code := Code, message := Msg}, E)
        end)
     || {Body, Status, Code, Msg} <- [
            %% No error_code: 400.
            {<<"{\"ok\":false}">>, 400, invalid_request, <<"Telegram HTTP 400">>},
            {<<"{\"ok\":false,\"error_code\":0}">>, 400, invalid_request, <<"Telegram HTTP 400">>},
            {<<"{\"ok\":false,\"error_code\":\"429\"}">>, 400, invalid_request,
                <<"Telegram HTTP 400">>},
            %% A float code truncates (Python int()), 0.5 -> 0.
            {<<"{\"ok\":false,\"error_code\":429.9}">>, 429, rate_limited, <<"Telegram HTTP 429">>},
            {<<"{\"ok\":false,\"error_code\":0.5}">>, 0, unknown, <<"Telegram HTTP 0">>},
            %% An integer no float can hold reads as absent.
            {
                <<"{\"ok\":false,\"error_code\":1", (binary:copy(<<"0">>, 400))/binary, "}">>,
                400,
                invalid_request,
                <<"Telegram HTTP 400">>
            },
            %% A non-object body (and an empty one) is a soft rejection too.
            {<<"[]">>, 400, invalid_request, <<"Telegram HTTP 400">>},
            {<<>>, 400, invalid_request, <<"Telegram HTTP 400">>},
            {<<"{\"ok\":\"true\"}">>, 400, invalid_request, <<"Telegram HTTP 400">>}
        ]
    ].

status_mapping_test_() ->
    [
        ?_test(begin
            Body = iolist_to_binary(
                io_lib:format("{\"ok\":false,\"error_code\":~b,\"description\":\"~s\"}", [S, D])
            ),
            {C, _} = cfg(<<"t">>, [?F:resp(S, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := S}},
                ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>})
            )
        end)
     || {S, D, Want} <- [
            %% Bot API server: bad token -> 401 "Unauthorized: invalid token
            %% specified"; a malformed /bot<token>/ path -> 404 "Not Found".
            {401, "Unauthorized: invalid token specified", auth_failed},
            {404, "Not Found", auth_failed},
            %% Every 403 is chat-scoped (blocked, deactivated, kicked, not a member).
            {403, "Forbidden: user is deactivated", invalid_recipient},
            {403, "Forbidden: bot was kicked from the group chat", invalid_recipient},
            {502, "Bad Gateway", provider_unavailable},
            {400, "Bad Request: PEER_ID_INVALID", invalid_recipient},
            {400, "Bad Request: USER_ID_INVALID", invalid_recipient},
            {400, "Bad Request: CHAT_ID_INVALID", invalid_recipient},
            {400, "Bad Request: message text is empty", invalid_request},
            {409, "Conflict", unknown}
        ]
    ].

error_without_description_test() ->
    {C, _} = cfg(<<"t">>, [?F:resp(500, <<"oops">>)]),
    ?assertMatch(
        {error, #{
            code := provider_unavailable,
            status := 500,
            message := <<"Telegram HTTP 500">>,
            cause := #{<<"raw">> := null}
        }},
        ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>})
    ).

%% ResponseParameters.retry_after: "the number of seconds left to wait before
%% the request can be repeated"; Telegram sends no Retry-After header.
retry_after_from_body_test() ->
    {C, _} = cfg(<<"t">>, [
        ?F:resp(
            429,
            <<"{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests: retry after 17\",",
                "\"parameters\":{\"retry_after\":17}}">>
        )
    ]),
    {error, E} = ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>}),
    ?assertMatch(#{code := rate_limited}, E),
    #{cause := Cause} = E,
    ?assertEqual(<<"17">>, maps:get(<<"retryAfter">>, Cause)),
    ?assertEqual(17, maps:get(<<"retryAfterSeconds">>, Cause)).

retry_after_header_wins_and_bad_body_values_ignored_test_() ->
    Body = fun(V) ->
        <<"{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":", V/binary, "}}">>
    end,
    [
        ?_test(begin
            {C, _} = cfg(<<"t">>, [?F:resp(429, Body(<<"17">>), #{<<"Retry-After">> => <<"3">>})]),
            {error, #{cause := Cause}} = ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>}),
            ?assertEqual(<<"3">>, maps:get(<<"retryAfter">>, Cause)),
            ?assertEqual(3, maps:get(<<"retryAfterSeconds">>, Cause))
        end)
    ] ++
        [
            ?_test(begin
                {C, _} = cfg(<<"t">>, [?F:resp(429, Body(V))]),
                {error, #{cause := Cause}} = ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>}),
                ?assertNot(maps:is_key(<<"retryAfter">>, Cause)),
                ?assertNot(maps:is_key(<<"retryAfterSeconds">>, Cause))
            end)
         || V <- [<<"1.5">>, <<"-1">>, <<"\"17\"">>, <<"true">>, <<"null">>]
        ].

message_id_shapes_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(<<"t">>, [?F:resp(200, <<"{\"ok\":true,\"result\":", Result/binary, "}">>)]),
            ?assertMatch(
                {ok, #{provider_message_id := Want}},
                ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>})
            )
        end)
     || {Result, Want} <- [
            {<<"{\"message_id\":7.0}">>, <<"7">>},
            {<<"{\"message_id\":7.5}">>, <<"7.5">>},
            {<<"{\"message_id\":\"7\"}">>, <<>>},
            {<<"{\"message_id\":true}">>, <<>>},
            {<<"{}">>, <<>>},
            {<<"true">>, <<>>}
        ]
    ].

%% --- test_passthrough_casing.py ---------------------------------------------

keys_as_given_test() ->
    Markup = #{
        <<"inline_keyboard">> => [
            [#{<<"text">> => <<"Open">>, <<"callback_data">> => <<"orderId:1">>}]
        ]
    },
    {C, P} = cfg(<<"123456:ABC-DEF">>, [
        ?F:resp(200, <<"{\"ok\":true,\"result\":{\"message_id\":1}}">>)
    ]),
    {ok, _} = ?N:send_chat(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{
            body => #{
                <<"parse_mode">> => <<"HTML">>, reply_markup => Markup, <<"parseMode">> => <<"x">>
            }
        }
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"HTML">>, maps:get(<<"parse_mode">>, Payload)),
    ?assertEqual(Markup, maps:get(<<"reply_markup">>, Payload)),
    %% A camelCase key is not rewritten onto the snake_case one.
    ?assertEqual(<<"x">>, maps:get(<<"parseMode">>, Payload)).

passthrough_query_and_headers_forwarded_test() ->
    {C, P} = cfg(<<"1:a">>, [?F:resp(200, <<"{\"ok\":true,\"result\":{\"message_id\":1}}">>)]),
    {ok, _} = ?N:send_chat(C, #{
        to => <<"1">>,
        body => <<"x">>,
        passthrough => #{query => #{k => <<"v">>}, headers => #{<<"X-Trace">> => <<"t">>}}
    }),
    Req = ?F:last(P),
    ?assertEqual(<<"v">>, ?F:qget(Req, <<"k">>)),
    ?assertEqual(<<"t">>, ?F:header(Req, <<"X-Trace">>)).

%% --- test_core.py ----------------------------------------------------------

%% A valid "<id>:<secret>" token is unchanged (the ":" stays literal); "/" and
%% "?" are escaped so they cannot retarget the request.
config_path_segments_escaped_test() ->
    Ok = ?F:resp(200, <<"{\"ok\":true,\"result\":{\"message_id\":1}}">>),
    {C, P} = cfg(<<"123456:ABC-def_1">>, [Ok]),
    {ok, _} = ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>}),
    ?assertEqual(<<"/bot123456:ABC-def_1/sendMessage">>, ?F:path_of(?F:last(P))),
    {C2, P2} = cfg(<<"1:a/b?c">>, [Ok]),
    {ok, _} = ?N:send_chat(C2, #{to => <<"1">>, body => <<"x">>}),
    ?assertEqual(<<"/bot1:a%2Fb%3Fc/sendMessage">>, ?F:path_of(?F:last(P2))).

bot_token_fun_is_resolved_test() ->
    {C, P} = cfg(fun() -> <<"9:z">> end, [?F:resp(200, <<"{\"ok\":true,\"result\":{}}">>)]),
    {ok, _} = ?N:send_chat(C, #{to => <<"1">>, body => <<"x">>}),
    ?assertEqual(<<"/bot9:z/sendMessage">>, ?F:path_of(?F:last(P))).

%% Telegram embeds the bot token in the URL PATH; a passthrough query adds a
%% `?key=` secret. A transport whose error embeds the URL must surface
%% neither.
transport_error_does_not_leak_path_or_query_secrets_test() ->
    BotToken = <<"123456:AAHsecretTOKENvalue0000000000000000000">>,
    QuerySecret = <<"QUERYSECRETvalue">>,
    C = #{provider => telegram, bot_token => BotToken, transport => {?MODULE, leak}},
    {error, E} = ?N:send_chat(C, #{
        to => <<"@channel">>, body => <<"hi">>, passthrough => #{query => #{key => QuerySecret}}
    }),
    ?assertEqual(
        #{
            code => provider_unavailable,
            message => <<"Upstream transport error (failed_connect)">>,
            provider_message => <<"Upstream transport error (failed_connect)">>,
            cause => #{<<"raw">> => #{<<"exception">> => <<"failed_connect">>}}
        },
        E
    ),
    Text = iolist_to_binary(io_lib:format("~p", [E])),
    [
        ?assertEqual(nomatch, binary:match(Text, S))
     || S <- [BotToken, <<"AAHsecretTOKENvalue">>, QuerySecret, <<"/bot">>, <<"api.telegram.org">>]
    ].

%% Python recovers a non-2xx that a BYO transport RAISES; an Erlang transport
%% returns every vendor answer as `{ok, Response}`, so the equivalent is that a
%% returned 401/429 is mapped by the connector (not reported as an outage) and
%% never echoes the path token.
non_2xx_is_mapped_by_the_connector_not_reported_as_an_outage_test() ->
    {C, _} = cfg(<<"123456:SECRET-TOKEN">>, [
        ?F:resp(401, <<"{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}">>)
    ]),
    {error, E} = ?N:send_chat(C, #{to => <<"@x">>, body => <<"hi">>}),
    ?assertMatch(#{status := 401, code := auth_failed}, E),
    ?assertEqual(
        nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [E])), <<"SECRET-TOKEN">>)
    ).

non_2xx_429_still_classifies_as_rate_limited_test() ->
    {C, _} = cfg(<<"t">>, [
        ?F:resp(
            429,
            <<"{\"ok\":false,\"description\":\"Too Many Requests\",\"parameters\":{\"retry_after\":30}}">>
        )
    ]),
    {error, E} = ?N:send_chat(C, #{to => <<"@x">>, body => <<"hi">>}),
    ?assertMatch(
        #{status := 429, code := rate_limited, cause := #{<<"retryAfterSeconds">> := 30}}, E
    ).

transport_failure_without_a_status_stays_provider_unavailable_test() ->
    C = #{provider => telegram, bot_token => <<"t">>, transport => {?MODULE, dead}},
    {error, E} = ?N:send_chat(C, #{to => <<"@x">>, body => <<"hi">>}),
    ?assertMatch(#{code := provider_unavailable}, E),
    ?assertNot(maps:is_key(status, E)).

%% --- misuse ------------------------------------------------------------------

misuse_is_badarg_without_echoing_the_token_test_() ->
    Secret = <<"123:SECRETBOT">>,
    [
        ?_test(begin
            {error, {badarg, Desc}} =
                try ?N:send_chat(C, I) of
                    R -> {returned, R}
                catch
                    error:Err -> {error, Err}
                end,
            ?assertEqual(nomatch, binary:match(Desc, Secret))
        end)
     || {C, I} <- [
            {#{provider => telegram}, #{}},
            {#{provider => telegram, bot_token => binary_to_list(Secret)}, #{}},
            {#{provider => telegram, bot_token => Secret, webhook_url => Secret}, #{}},
            {#{provider => telegram, bot_token => Secret}, #{to => 1}},
            {#{provider => telegram, bot_token => Secret}, #{subject => <<"s">>}}
        ]
    ].
