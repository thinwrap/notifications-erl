-module(thinwrap_notifications_apns_tests).

%% Ported from the Python sibling's tests/test_apns.py, plus the ES256
%% round-trip of test_core.py (verified here with public_key:verify).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(K, thinwrap_notifications_push_keys).
-define(N, thinwrap_notifications).

-define(CACHE_KEY, <<"apns:TEAM123456:KEY1234567:com.acme.app">>).

base() ->
    #{
        provider => apns,
        team_id => <<"TEAM123456">>,
        key_id => <<"KEY1234567">>,
        private_key => ?K:ec_pem(),
        bundle_id => <<"com.acme.app">>,
        env => <<"production">>
    }.

cfg(Extra, Responses) -> ?F:config(maps:merge(base(), Extra), Responses).

ok_resp(Id) -> ?F:resp(200, <<>>, #{<<"apns-id">> => Id}).

now_s() -> erlang:system_time(millisecond) / 1000.

bearer(Req) ->
    <<"bearer ", Jwt/binary>> = ?F:header(Req, <<"authorization">>),
    Jwt.

fails_fast_with_default_transport_test() ->
    %% No transport injected → the default httpc (HTTP/1.1-only) cannot reach
    %% APNs (HTTP/2). Must fail fast with invalid_request, before any network
    %% call and before signing.
    {error, E} = ?N:send_push(base(), #{to => <<"devtok">>, title => <<"Hi">>, body => <<"there">>}),
    ?assertMatch(#{code := invalid_request}, E),
    ?assertNot(maps:is_key(status, E)),
    ?assertMatch({match, _}, re:run(maps:get(message, E), "HTTP/2")),
    %% An explicitly configured httpc is just as HTTP/1.1-only.
    ?assertMatch(
        {error, #{code := invalid_request}},
        ?N:send_push((base())#{transport => {thinwrap_notifications_httpc, #{}}}, #{to => <<"t">>})
    ).

send_production_host_and_headers_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"apns-unique-id">>)]),
    {ok, R} = ?N:send_push(C, #{
        to => <<"devtok">>, title => <<"Hi">>, body => <<"there">>, data => #{<<"k">> => <<"v">>}
    }),
    ?assertEqual(
        #{success => true, status => sent, provider_message_id => <<"apns-unique-id">>, raw => #{}},
        R
    ),
    Req = ?F:last(P),
    ?assertEqual(<<"api.push.apple.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/3/device/devtok">>, ?F:path_of(Req)),
    %% ES256 JWT bearer auth (APNs uses lowercase header + scheme).
    ?assertEqual(3, length(binary:split(bearer(Req), <<".">>, [global]))),
    ?assertEqual(<<"com.acme.app">>, ?F:header(Req, <<"apns-topic">>)),
    ?assertEqual(<<"alert">>, ?F:header(Req, <<"apns-push-type">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"content-type">>)),
    ?assertEqual(undefined, ?F:header(Req, <<"apns-priority">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(
        #{<<"title">> => <<"Hi">>, <<"body">> => <<"there">>},
        maps:get(<<"alert">>, maps:get(<<"aps">>, Payload))
    ),
    %% Custom data merges at the payload root.
    ?assertEqual(<<"v">>, maps:get(<<"k">>, Payload)).

provider_jwt_is_es256_raw_signature_test() ->
    %% test_core.py's ES256 round-trip for PKCS#8 and SEC1: the signature is
    %% IEEE P1363 raw r||s (64 bytes), never DER.
    [
        begin
            {C, P} = cfg(#{private_key => ?K:ec_pem(Form)}, [ok_resp(<<"id">>)]),
            Before = erlang:system_time(second),
            {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
            Jwt = bearer(?F:last(P)),
            ?assert(?K:verify_es256(Jwt)),
            ?assertEqual(
                #{<<"alg">> => <<"ES256">>, <<"kid">> => <<"KEY1234567">>, <<"typ">> => <<"JWT">>},
                ?K:jwt_header(Jwt)
            ),
            #{<<"iss">> := <<"TEAM123456">>, <<"iat">> := Iat} = Claims = ?K:jwt_claims(Jwt),
            ?assertEqual(2, map_size(Claims)),
            ?assert(Iat >= Before)
        end
     || Form <- [pkcs8, sec1]
    ].

sandbox_host_when_not_production_test() ->
    {C, P} = cfg(#{env => <<>>}, [ok_resp(<<"id-1">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    ?assertEqual(<<"api.sandbox.push.apple.com">>, ?F:host_of(?F:last(P))).

absent_env_is_sandbox_test() ->
    {C, P} = ?F:config(maps:remove(env, base()), [ok_resp(<<"id">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    ?assertEqual(<<"api.sandbox.push.apple.com">>, ?F:host_of(?F:last(P))).

known_envs_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{env => Env}, [ok_resp(<<"id">>)]),
            {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, title => <<"Hi">>}),
            ?assertEqual(Host, ?F:host_of(?F:last(P)))
        end)
     || {Env, Host} <- [
            {<<>>, <<"api.sandbox.push.apple.com">>},
            {<<"sandbox">>, <<"api.sandbox.push.apple.com">>},
            {<<"production">>, <<"api.push.apple.com">>}
        ]
    ].

unknown_env_rejected_before_signing_test_() ->
    %% A typo would otherwise send production tokens to the sandbox, where they
    %% fail as BadDeviceToken (invalid_recipient) and get purged.
    [
        ?_test(begin
            {C, P} = cfg(#{env => Env}, [ok_resp(<<"id">>)]),
            ?assertMatch(
                {error, #{code := invalid_request}},
                ?N:send_push(C, #{to => <<"devtok">>, title => <<"Hi">>})
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || Env <- [<<"prod">>, <<"Production">>, <<"development">>, <<"live">>]
    ].

data_only_is_background_push_type_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id-2">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, data => #{<<"k">> => <<"v">>}}),
    ?assertEqual(<<"background">>, ?F:header(?F:last(P), <<"apns-push-type">>)).

data_cannot_clobber_aps_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>, title => <<"Hi">>, data => #{<<"aps">> => <<"x">>, <<"k">> => <<"v">>}
    }),
    ?assertEqual(
        #{<<"aps">> => #{<<"alert">> => #{<<"title">> => <<"Hi">>}}, <<"k">> => <<"v">>},
        ?F:body_json(?F:last(P))
    ).

token_cache_hit_skips_signing_test() ->
    {Cache, _} = ?K:mem_cache(),
    #{set := Set} = Cache,
    Set(?CACHE_KEY, <<"CACHED.JWT.SIG">>, now_s() + 1000),
    %% A key that cannot sign proves the cached token was used.
    {C, P} = cfg(#{token_cache => Cache, private_key => <<"not a key">>}, [ok_resp(<<"id-3">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    ?assertEqual(<<"bearer CACHED.JWT.SIG">>, ?F:header(?F:last(P), <<"authorization">>)).

token_cache_populated_after_signing_test() ->
    {Cache, CP} = ?K:mem_cache(),
    {C, P} = cfg(#{token_cache => Cache}, [ok_resp(<<"id-4">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    #{?CACHE_KEY := {Tok, ExpiresAt}} = ?K:cache_entries(CP),
    ?assertEqual(bearer(?F:last(P)), Tok),
    ?assertEqual(3, length(binary:split(Tok, <<".">>, [global]))),
    %% 50-minute TTL, inside Apple's 20–60 minute window.
    ?assert(ExpiresAt > now_s() + 50 * 60 - 5),
    ?assert(ExpiresAt =< now_s() + 50 * 60).

bad_device_token_400_maps_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [?F:resp(400, <<"{\"reason\":\"BadDeviceToken\"}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient, status := 400, provider_message := <<"BadDeviceToken">>
        }},
        ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>})
    ).

forbidden_maps_auth_failed_test() ->
    {C, _} = cfg(#{}, [?F:resp(403, <<"{\"reason\":\"InvalidProviderToken\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed}}, ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>})
    ).

gone_maps_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [?F:resp(410, <<"{\"reason\":\"Unregistered\"}">>)]),
    ?assertMatch(
        {error, #{code := invalid_recipient}},
        ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>})
    ).

status_table_test_() ->
    [
        ?_test(begin
            Body =
                case Reason of
                    <<>> -> <<>>;
                    _ -> json:encode(#{<<"reason">> => Reason})
                end,
            {C, _} = cfg(#{}, [?F:resp(S, Body)]),
            {error, E} = ?N:send_push(C, #{to => <<"devtok">>, title => <<"Hi">>}),
            ?assertMatch(#{code := Want, status := S}, E),
            Reason =:= <<>> andalso
                ?assertEqual(
                    <<"APNs HTTP ", (integer_to_binary(S))/binary>>, maps:get(provider_message, E)
                )
        end)
     || {S, Reason, Want} <- [
            {400, <<"BadTopic">>, invalid_request},
            {403, <<"BadDeviceToken">>, invalid_recipient},
            {403, <<"ExpiredProviderToken">>, auth_failed},
            {413, <<"PayloadTooLarge">>, invalid_request},
            {405, <<"BadMethod">>, unknown},
            {404, <<>>, unknown},
            {500, <<"InternalServerError">>, provider_unavailable},
            {502, <<>>, provider_unavailable},
            {503, <<"ServiceUnavailable">>, provider_unavailable},
            {504, <<>>, provider_unavailable}
        ]
    ].

background_push_priority_5_and_content_available_test() ->
    %% Apple: for apns-push-type background "Always use priority 5. Using
    %% priority 10 is an error"; omitting apns-priority means 10. The aps
    %% dictionary "includes only the content-available key".
    {C, P} = cfg(#{}, [ok_resp(<<"id-bg">>)]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, data => #{<<"k">> => <<"v">>}}),
    Req = ?F:last(P),
    ?assertEqual(<<"background">>, ?F:header(Req, <<"apns-push-type">>)),
    ?assertEqual(<<"5">>, ?F:header(Req, <<"apns-priority">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(#{<<"content-available">> => 1}, maps:get(<<"aps">>, Payload)),
    ?assertEqual(<<"v">>, maps:get(<<"k">>, Payload)).

caller_priority_and_push_type_respected_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id-bg2">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>,
        data => #{<<"k">> => <<"v">>},
        passthrough => #{headers => #{<<"APNS-Priority">> => <<"1">>}}
    }),
    Req = ?F:last(P),
    ?assertEqual(<<"1">>, ?F:header(Req, <<"apns-priority">>)),
    ?assertEqual(1, length([N || N <- ?F:header_names(Req), N =:= <<"apns-priority">>])).

passthrough_alert_is_alert_push_type_test() ->
    %% The push type follows the MERGED payload: an aps.alert supplied through
    %% passthrough is an alert, not a background push.
    {C, P} = cfg(#{}, [ok_resp(<<"id-alert">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>,
        passthrough => #{body => #{aps => #{alert => #{title => <<"From passthrough">>}}}}
    }),
    Req = ?F:last(P),
    ?assertEqual(<<"alert">>, ?F:header(Req, <<"apns-push-type">>)),
    ?assertEqual(undefined, ?F:header(Req, <<"apns-priority">>)),
    ?assertNot(maps:is_key(<<"content-available">>, maps:get(<<"aps">>, ?F:body_json(Req)))).

too_many_provider_token_updates_is_auth_failed_test() ->
    %% Apple: 429 TooManyProviderTokenUpdates — "The provider's authentication
    %% token is being updated too often." Without token_cache every retry
    %% re-trips it.
    {C, _} = cfg(#{}, [?F:resp(429, <<"{\"reason\":\"TooManyProviderTokenUpdates\"}">>)]),
    {error, E} = ?N:send_push(C, #{to => <<"devtok">>, title => <<"Hi">>}),
    ?assertMatch(#{code := auth_failed, status := 429}, E),
    ?assertMatch({_, _}, binary:match(maps:get(provider_message, E), <<"token_cache">>)).

plain_429_is_rate_limited_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(429, <<"{\"reason\":\"TooManyRequests\"}">>, #{<<"Retry-After">> => <<"3">>})
    ]),
    ?assertMatch(
        {error, #{code := rate_limited, cause := #{<<"retryAfterSeconds">> := 3}}},
        ?N:send_push(C, #{to => <<"devtok">>, title => <<"Hi">>})
    ).

badge_sound_or_string_alert_is_alert_push_test_() ->
    %% Apple: the alert push type is "for notifications that trigger a user
    %% interaction—for example, an alert, badge, or sound". A badge of 0 clears
    %% it, so presence counts, not truthiness.
    [
        ?_test(begin
            {C, P} = cfg(#{}, [ok_resp(<<"id-a">>)]),
            {ok, _} = ?N:send_push(C, #{
                to => <<"devtok">>, passthrough => #{body => #{<<"aps">> => Aps}}
            }),
            Req = ?F:last(P),
            ?assertEqual(<<"alert">>, ?F:header(Req, <<"apns-push-type">>)),
            ?assertEqual(undefined, ?F:header(Req, <<"apns-priority">>)),
            ?assertEqual(Aps, maps:get(<<"aps">>, ?F:body_json(Req)))
        end)
     || Aps <- [
            #{<<"badge">> => 3},
            #{<<"badge">> => 0},
            #{<<"sound">> => <<"default">>},
            #{<<"alert">> => <<"Plain string alert">>}
        ]
    ].

null_badge_is_not_user_facing_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>, passthrough => #{body => #{<<"aps">> => #{<<"badge">> => null}}}
    }),
    ?assertEqual(<<"background">>, ?F:header(?F:last(P), <<"apns-push-type">>)).

non_map_aps_is_replaced_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>, passthrough => #{body => #{<<"aps">> => <<"x">>}}
    }),
    ?assertEqual(#{<<"content-available">> => 1}, maps:get(<<"aps">>, ?F:body_json(?F:last(P)))).

caller_background_header_gets_background_extras_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id-b">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>,
        passthrough => #{
            body => #{<<"aps">> => #{<<"badge">> => 1}},
            headers => #{<<"apns-push-type">> => <<" Background ">>}
        }
    }),
    Req = ?F:last(P),
    ?assertEqual(<<" Background ">>, ?F:header(Req, <<"apns-push-type">>)),
    ?assertEqual(<<"5">>, ?F:header(Req, <<"apns-priority">>)),
    ?assertEqual(
        #{<<"badge">> => 1, <<"content-available">> => 1}, maps:get(<<"aps">>, ?F:body_json(Req))
    ).

caller_content_available_kept_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>,
        passthrough => #{body => #{<<"aps">> => #{<<"content-available">> => 0}}}
    }),
    ?assertEqual(#{<<"content-available">> => 0}, maps:get(<<"aps">>, ?F:body_json(?F:last(P)))).

device_token_path_escaped_and_query_not_forwarded_test() ->
    {C, P} = cfg(#{}, [ok_resp(<<"id">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"a/b?c">>, title => <<"t">>, passthrough => #{query => #{<<"q">> => <<"1">>}}
    }),
    Req = ?F:last(P),
    ?assertEqual(<<"https://api.push.apple.com/3/device/a%2Fb%3Fc">>, maps:get(url, Req)).

missing_apns_id_is_empty_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<>>)]),
    ?assertMatch(
        {ok, #{provider_message_id := <<>>, raw := R}} when R =:= #{},
        ?N:send_push(C, #{to => <<"devtok">>, title => <<"t">>})
    ).
