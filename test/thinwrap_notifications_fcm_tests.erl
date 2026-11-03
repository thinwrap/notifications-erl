-module(thinwrap_notifications_fcm_tests).

%% Ported from the Python sibling's tests/test_fcm.py, plus the RS256
%% round-trip of test_core.py (verified here with public_key:verify).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(K, thinwrap_notifications_push_keys).
-define(N, thinwrap_notifications).

-define(CLIENT_EMAIL, <<"svc@proj-1.iam.gserviceaccount.com">>).
%% The cache key folds in the credential identity.
-define(CACHE_KEY, <<"fcm:proj-1:svc@proj-1.iam.gserviceaccount.com">>).
-define(TOKEN_OK, <<"{\"access_token\":\"ya29.TOKEN\",\"expires_in\":3599}">>).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => fcm,
                project_id => <<"proj-1">>,
                client_email => ?CLIENT_EMAIL,
                private_key => ?K:rsa_pem()
            },
            Extra
        ),
        Responses
    ).

now_s() -> erlang:system_time(millisecond) / 1000.

send_exchanges_token_then_sends_test() ->
    %% First response = the OAuth token exchange; second = messages:send.
    {C, P} = cfg(#{}, [
        ?F:resp(200, <<"{\"access_token\":\"ya29.TOKEN\",\"expires_in\":3599}">>),
        ?F:resp(200, <<"{\"name\":\"projects/proj-1/messages/0:123\"}">>)
    ]),
    {ok, R} = ?N:send_push(C, #{
        to => <<"devtok">>, title => <<"Hi">>, body => <<"there">>, data => #{<<"k">> => <<"v">>}
    }),
    ?assertMatch(
        #{
            success := true,
            status := sent,
            provider_message_id := <<"projects/proj-1/messages/0:123">>
        },
        R
    ),
    [Exchange, Send] = ?F:calls(P),
    %% Call 0: token exchange (form POST to Google's OAuth endpoint).
    ?assertEqual(<<"oauth2.googleapis.com">>, ?F:host_of(Exchange)),
    ?assertEqual(<<"/token">>, ?F:path_of(Exchange)),
    ?assertEqual(<<"application/x-www-form-urlencoded">>, ?F:header(Exchange, <<"Content-Type">>)),
    ?assertEqual(undefined, ?F:header(Exchange, <<"Authorization">>)),
    Form = ?F:body_form_single(Exchange),
    ?assertEqual(
        <<"urn:ietf:params:oauth:grant-type:jwt-bearer">>, maps:get(<<"grant_type">>, Form)
    ),
    Jwt = maps:get(<<"assertion">>, Form),
    ?assertEqual(3, length(binary:split(Jwt, <<".">>, [global]))),
    %% Call 1: messages:send with the bearer token.
    ?assertEqual(<<"fcm.googleapis.com">>, ?F:host_of(Send)),
    ?assertEqual(<<"/v1/projects/proj-1/messages:send">>, ?F:path_of(Send)),
    ?assertEqual(<<"Bearer ya29.TOKEN">>, ?F:header(Send, <<"Authorization">>)),
    #{<<"message">> := Msg} = ?F:body_json(Send),
    ?assertEqual(<<"devtok">>, maps:get(<<"token">>, Msg)),
    ?assertEqual(
        #{<<"title">> => <<"Hi">>, <<"body">> => <<"there">>}, maps:get(<<"notification">>, Msg)
    ),
    ?assertEqual(#{<<"k">> => <<"v">>}, maps:get(<<"data">>, Msg)).

service_account_jwt_is_rs256_signed_test() ->
    %% test_core.py's RS256 round-trip, for both PEM forms the sibling reads.
    [
        begin
            {C, P} = cfg(#{private_key => ?K:rsa_pem(Form)}, [
                ?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)
            ]),
            Before = erlang:system_time(second),
            {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
            Jwt = maps:get(<<"assertion">>, ?F:body_form_single(hd(?F:calls(P)))),
            ?assert(?K:verify_rs256(Jwt)),
            ?assertEqual(#{<<"alg">> => <<"RS256">>, <<"typ">> => <<"JWT">>}, ?K:jwt_header(Jwt)),
            #{<<"iat">> := Iat, <<"exp">> := Exp} = Claims = ?K:jwt_claims(Jwt),
            ?assertMatch(
                #{
                    <<"iss">> := ?CLIENT_EMAIL,
                    <<"scope">> := <<"https://www.googleapis.com/auth/firebase.messaging">>,
                    <<"aud">> := <<"https://oauth2.googleapis.com/token">>
                },
                Claims
            ),
            ?assert(Iat >= Before),
            ?assertEqual(Iat + 3600, Exp),
            %% Header and claims keep the siblings' key order.
            [H64, C64, _] = binary:split(Jwt, <<".">>, [global]),
            ?assertMatch(
                <<"{\"alg\":\"RS256\",\"typ\":\"JWT\"}">>,
                base64:decode(H64, #{mode => urlsafe, padding => false})
            ),
            ?assertMatch(
                <<"{\"iss\":", _/binary>>, base64:decode(C64, #{mode => urlsafe, padding => false})
            )
        end
     || Form <- [pkcs8, pkcs1]
    ].

private_key_fun_is_resolved_at_use_test() ->
    Pem = ?K:rsa_pem(),
    {C, P} = cfg(#{private_key => fun() -> Pem end}, [
        ?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)
    ]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    ?assert(?K:verify_rs256(maps:get(<<"assertion">>, ?F:body_form_single(hd(?F:calls(P)))))).

token_cache_hit_skips_exchange_test() ->
    {Cache, _} = ?K:mem_cache(),
    #{set := Set} = Cache,
    Set(?CACHE_KEY, <<"CACHED">>, now_s() + 1000),
    {C, P} = cfg(#{token_cache => Cache}, [
        ?F:resp(200, <<"{\"name\":\"projects/proj-1/messages/1\"}">>)
    ]),
    {ok, #{success := true}} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    %% Only ONE HTTP call: the send. No token exchange.
    ?assertEqual(1, length(?F:calls(P))),
    ?assertEqual(<<"Bearer CACHED">>, ?F:header(?F:last(P), <<"Authorization">>)).

token_cache_expired_entry_is_refreshed_test() ->
    {Cache, CP} = ?K:mem_cache(),
    #{set := Set} = Cache,
    Set(?CACHE_KEY, <<"STALE">>, now_s() - 1),
    {C, P} = cfg(#{token_cache => Cache}, [
        ?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)
    ]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    ?assertEqual(2, length(?F:calls(P))),
    ?assertMatch(#{?CACHE_KEY := {<<"ya29.TOKEN">>, _}}, ?K:cache_entries(CP)).

token_cache_populated_after_exchange_test() ->
    {Cache, CP} = ?K:mem_cache(),
    {C, _} = cfg(#{token_cache => Cache}, [
        ?F:resp(200, <<"{\"access_token\":\"ya29.FRESH\",\"expires_in\":3599}">>),
        ?F:resp(200, <<"{\"name\":\"projects/proj-1/messages/2\"}">>)
    ]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    #{?CACHE_KEY := {Tok, ExpiresAt}} = ?K:cache_entries(CP),
    ?assertEqual(<<"ya29.FRESH">>, Tok),
    ?assert(ExpiresAt > now_s()),
    %% Google reported expires_in=3599; the cached expiry is shaved by the skew
    %% margin (60s), so it sits comfortably below now + 3599.
    ?assert(ExpiresAt < now_s() + 3599 - 59).

cache_key_includes_client_email_test() ->
    %% Two service accounts for the SAME project must NOT share a cache entry:
    %% after SA "a" caches its token, SA "b" must mint its own.
    {Cache, CP} = ?K:mem_cache(),
    #{set := Set} = Cache,
    Set(<<"fcm:proj-1:a@proj-1.iam.gserviceaccount.com">>, <<"TOKEN_A">>, now_s() + 1000),
    {C, P} = cfg(
        #{client_email => <<"b@proj-1.iam.gserviceaccount.com">>, token_cache => Cache},
        [
            ?F:resp(200, <<"{\"access_token\":\"ya29.TOKEN_B\",\"expires_in\":3599}">>),
            ?F:resp(200, <<"{\"name\":\"projects/proj-1/messages/9\"}">>)
        ]
    ),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    ?assertEqual(2, length(?F:calls(P))),
    ?assertEqual(<<"oauth2.googleapis.com">>, ?F:host_of(hd(?F:calls(P)))),
    ?assertEqual(<<"Bearer ya29.TOKEN_B">>, ?F:header(?F:last(P), <<"Authorization">>)),
    Entries = ?K:cache_entries(CP),
    ?assertMatch(
        {<<"TOKEN_A">>, _}, maps:get(<<"fcm:proj-1:a@proj-1.iam.gserviceaccount.com">>, Entries)
    ),
    ?assertMatch(
        {<<"ya29.TOKEN_B">>, _},
        maps:get(<<"fcm:proj-1:b@proj-1.iam.gserviceaccount.com">>, Entries)
    ).

send_error_maps_code_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(200, ?TOKEN_OK),
        ?F:resp(401, <<"{\"error\":{\"status\":\"UNAUTHENTICATED\",\"message\":\"bad creds\"}}">>)
    ]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 401, provider_message := <<"bad creds">>}},
        ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>})
    ).

not_found_maps_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(200, ?TOKEN_OK),
        ?F:resp(404, <<"{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"token not found\"}}">>)
    ]),
    ?assertMatch(
        {error, #{code := invalid_recipient}},
        ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>})
    ).

token_exchange_failure_is_auth_failed_test() ->
    {C, P} = cfg(#{}, [?F:resp(400, <<"{\"error\":\"invalid_grant\"}">>)]),
    {error, E} = ?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}),
    ?assertMatch(
        #{
            code := auth_failed,
            status := 400,
            provider_message :=
                <<"FCM OAuth token exchange failed: 400 {\"error\":\"invalid_grant\"}">>,
            cause := #{<<"raw">> := #{<<"error">> := <<"invalid_grant">>}}
        },
        E
    ),
    %% No send call was made — only the failed token exchange.
    ?assertEqual(1, length(?F:calls(P))).

token_exchange_empty_body_message_test() ->
    {C, _} = cfg(#{}, [?F:resp(401, <<>>)]),
    ?assertMatch(
        {error, #{
            code := auth_failed, provider_message := <<"FCM OAuth token exchange failed: 401">>
        }},
        ?N:send_push(C, #{to => <<"devtok">>})
    ),
    %% Invalid UTF-8 in the body is replaced, as Python's decode("utf-8", "replace").
    {C2, _} = cfg(#{}, [?F:resp(500, <<"bad", 16#FF, "x", 16#E2, 16#82>>)]),
    {error, #{provider_message := M}} = ?N:send_push(C2, #{to => <<"devtok">>}),
    ?assertEqual(
        <<"FCM OAuth token exchange failed: 500 bad", 16#FFFD/utf8, "x", 16#FFFD/utf8>>, M
    ).

token_exchange_200_without_access_token_is_auth_failed_test() ->
    %% A 200 with a token-less body must not become (and be cached as) an
    %% empty Bearer.
    {Cache, CP} = ?K:mem_cache(),
    {C, P} = cfg(#{token_cache => Cache}, [?F:resp(200, <<"{\"token_type\":\"Bearer\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 200}}, ?N:send_push(C, #{to => <<"devtok">>})
    ),
    ?assertEqual(1, length(?F:calls(P))),
    ?assertEqual(#{}, ?K:cache_entries(CP)).

passthrough_target_replaces_token_test_() ->
    %% projects.messages: token/fid/topic/condition are "mutually exclusive
    %% fields. At most one of the fields will be set".
    [
        ?_test(begin
            {C, P} = cfg(#{}, [?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)]),
            {ok, _} = ?N:send_push(C, #{
                to => <<"devtok">>,
                title => <<"Hi">>,
                passthrough => #{body => #{message => Target}}
            }),
            #{<<"message">> := M} = ?F:body_json(?F:last(P)),
            ?assertNot(maps:is_key(<<"token">>, M)),
            [?assertEqual(V, maps:get(atom_to_binary(K), M)) || K := V <- Target]
        end)
     || Target <- [
            #{topic => <<"news">>},
            #{condition => <<"'a' in topics">>},
            #{fid => <<"fid-1">>}
        ]
    ].

passthrough_empty_target_keeps_token_test() ->
    %% Only a truthy target replaces the token (Python `any(message.get(k))`).
    {C, P} = cfg(#{}, [?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>,
        passthrough => #{body => #{<<"message">> => #{<<"topic">> => <<>>, <<"fid">> => null}}}
    }),
    ?assertMatch(#{<<"message">> := #{<<"token">> := <<"devtok">>}}, ?F:body_json(?F:last(P))).

passthrough_rides_verbatim_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)]),
    {ok, _} = ?N:send_push(C, #{
        to => <<"devtok">>,
        title => <<"Hi">>,
        passthrough => #{
            body => #{<<"message">> => #{<<"android">> => #{<<"priority">> => <<"high">>}}},
            headers => #{<<"X-Trace">> => <<"t1">>},
            query => #{<<"q">> => <<"1">>}
        }
    }),
    [Exchange, Send] = ?F:calls(P),
    #{<<"message">> := M} = ?F:body_json(Send),
    ?assertEqual(#{<<"priority">> => <<"high">>}, maps:get(<<"android">>, M)),
    ?assertEqual(<<"devtok">>, maps:get(<<"token">>, M)),
    ?assertEqual(<<"t1">>, ?F:header(Send, <<"X-Trace">>)),
    %% The passthrough reaches the send only: never the token exchange, and the
    %% query is not forwarded.
    ?assertEqual(undefined, ?F:header(Exchange, <<"X-Trace">>)),
    ?assertEqual(nomatch, binary:match(maps:get(url, Send), <<"?">>)).

empty_to_omits_token_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)]),
    {ok, _} = ?N:send_push(C, #{title => <<"Hi">>}),
    #{<<"message">> := M} = ?F:body_json(?F:last(P)),
    ?assertNot(maps:is_key(<<"token">>, M)),
    ?assertNot(maps:is_key(<<"data">>, M)).

oauth_exchange_status_mapping_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{}, [?F:resp(S, <<"{\"error\":\"x\"}">>)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_push(C, #{to => <<"devtok">>})),
            ?assertEqual(1, length(?F:calls(P)))
        end)
     || {S, Want} <- [
            %% invalid_grant / invalid_client
            {400, auth_failed},
            {401, auth_failed},
            {429, rate_limited},
            {500, provider_unavailable},
            {503, provider_unavailable}
        ]
    ].

oauth_exchange_retry_after_surfaces_in_cause_test() ->
    {C, _} = cfg(#{}, [?F:resp(429, <<"{}">>, #{<<"Retry-After">> => <<"7">>})]),
    ?assertMatch(
        {error, #{
            code := rate_limited,
            cause := #{<<"retryAfter">> := <<"7">>, <<"retryAfterSeconds">> := 7}
        }},
        ?N:send_push(C, #{to => <<"devtok">>})
    ).

bad_gateway_is_provider_unavailable_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, ?TOKEN_OK), ?F:resp(502, <<"<html>Bad Gateway</html>">>)]),
    ?assertMatch(
        {error, #{
            code := provider_unavailable,
            provider_message := <<"FCM HTTP 502">>,
            cause := #{<<"raw">> := null}
        }},
        ?N:send_push(C, #{to => <<"devtok">>, title => <<"Hi">>})
    ).

status_table_test_() ->
    %% HTTP status first; the vendor error.status disambiguates a
    %% non-canonical HTTP status.
    [
        ?_test(begin
            Body = json:encode(#{<<"error">> => #{<<"status">> => St, <<"message">> => <<"m">>}}),
            {C, _} = cfg(#{}, [?F:resp(200, ?TOKEN_OK), ?F:resp(S, Body)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_push(C, #{to => <<"devtok">>}))
        end)
     || {S, St, Want} <- [
            {403, <<"PERMISSION_DENIED">>, auth_failed},
            {429, <<"RESOURCE_EXHAUSTED">>, rate_limited},
            {400, <<"INVALID_ARGUMENT">>, invalid_request},
            {409, <<"UNAUTHENTICATED">>, auth_failed},
            {409, <<"SENDER_ID_MISMATCH">>, auth_failed},
            {409, <<"INVALID_ARGUMENT">>, invalid_request},
            {409, <<"NOT_FOUND">>, invalid_recipient},
            {409, <<"QUOTA_EXCEEDED">>, rate_limited},
            {409, <<"RESOURCE_EXHAUSTED">>, rate_limited},
            {409, <<"UNAVAILABLE">>, provider_unavailable},
            {409, <<"INTERNAL">>, provider_unavailable},
            {409, <<"ABORTED">>, unknown}
        ]
    ].

project_id_path_escaped_test() ->
    {C, P} = cfg(#{project_id => <<"proj/../x">>}, [
        ?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"projects/p/messages/4\"}">>)
    ]),
    {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, title => <<"Hi">>}),
    ?assertEqual(<<"/v1/projects/proj%2F..%2Fx/messages:send">>, ?F:path_of(?F:last(P))).

transport_failure_on_exchange_is_provider_unavailable_test() ->
    {C, _} = cfg(#{}, [{error, timeout}]),
    ?assertMatch(
        {error, #{
            code := provider_unavailable,
            cause := #{<<"raw">> := #{<<"exception">> := <<"timeout">>}}
        }},
        ?N:send_push(C, #{to => <<"devtok">>})
    ).

oauth_error_body_replacement_matches_python_test_() ->
    %% Expected values produced by Python's bytes.decode("utf-8", "replace"):
    %% one U+FFFD per maximal ill-formed subpart.
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(500, list_to_binary(In))]),
            {error, #{provider_message := <<"FCM OAuth token exchange failed: 500 ", Text/binary>>}} =
                ?N:send_push(C, #{to => <<"devtok">>}),
            ?assertEqual(Want, unicode:characters_to_list(Text))
        end)
     || {In, Want} <- [
            {[195], [65533]},
            {[195, 65], [65533, 65]},
            {[224, 128, 65], [65533, 65533, 65]},
            {[224, 160], [65533]},
            {[237, 160, 128], [65533, 65533, 65533]},
            {[240, 159, 152], [65533]},
            {[244, 144, 128, 128], [65533, 65533, 65533, 65533]},
            {[241, 128, 128], [65533]},
            {[128, 128], [65533, 65533]},
            {[254, 111, 107], [65533, 111, 107]},
            {[225, 128, 195, 169], [65533, 233]}
        ]
    ].

passthrough_falsy_or_odd_targets_keep_token_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{}, [?F:resp(200, ?TOKEN_OK), ?F:resp(200, <<"{\"name\":\"n\"}">>)]),
            {ok, _} = ?N:send_push(C, #{to => <<"devtok">>, passthrough => #{body => Pt}}),
            ?assertEqual(Want, maps:get(<<"message">>, ?F:body_json(?F:last(P))))
        end)
     || {Pt, Want} <- [
            {#{<<"message">> => #{<<"topic">> => false, <<"fid">> => []}}, #{
                <<"token">> => <<"devtok">>, <<"topic">> => false, <<"fid">> => []
            }},
            {#{<<"message">> => #{<<"condition">> => #{}, <<"topic">> => 0}}, #{
                <<"token">> => <<"devtok">>, <<"condition">> => #{}, <<"topic">> => 0
            }},
            %% A non-map message replaces the connector's wholesale.
            {#{<<"message">> => <<"raw">>}, <<"raw">>}
        ]
    ].
