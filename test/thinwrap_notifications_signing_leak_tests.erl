-module(thinwrap_notifications_signing_leak_tests).

%% Ported from the Python sibling's tests/test_signing_leak.py: an FCM/APNs
%% key that fails to parse or sign must come back as auth_failed with only the
%% failure kind in `cause` — never the crypto exception, whose reason can hold
%% the private-key bytes (public_key's ASN.1 errors embed the DER) — and
%% before any HTTP request.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(K, thinwrap_notifications_push_keys).
-define(N, thinwrap_notifications).

%% Valid base64 ("MIGHAgEA") that decodes to a DER structure too short to parse.
truncated_pkcs8() -> ?K:armored(<<16#30, 16#81, 16#87, 2, 1, 0>>).

fcm(Pem) ->
    ?F:config(
        #{
            provider => fcm,
            project_id => <<"p">>,
            client_email => <<"svc@p.iam.gserviceaccount.com">>,
            private_key => Pem
        },
        [?F:resp(200, <<"{\"access_token\":\"x\",\"expires_in\":3599}">>)]
    ).

apns(Pem) ->
    ?F:config(
        #{
            provider => apns,
            team_id => <<"TEAM123456">>,
            key_id => <<"KEY1234567">>,
            private_key => Pem,
            bundle_id => <<"com.acme.app">>,
            env => <<"production">>
        },
        [?F:resp(200, <<>>, #{<<"apns-id">> => <<"x">>})]
    ).

assert_no_key_leak({error, Err}, Pem, Provider) ->
    ?assertMatch(#{code := auth_failed, cause := #{<<"raw">> := #{<<"exception">> := _}}}, Err),
    #{cause := #{<<"raw">> := #{<<"exception">> := Kind}} = Cause} = Err,
    %% The cause is the documented {raw: {exception: Kind}} shape and nothing else.
    ?assertEqual(#{<<"raw">> => #{<<"exception">> => Kind}}, Cause),
    ?assertMatch({match, _}, re:run(Kind, "^[a-z_0-9]+\\z")),
    ?assertEqual(
        <<Provider/binary, " JWT signing failed (", Kind/binary, ")">>, maps:get(message, Err)
    ),
    ?assertEqual(maps:get(message, Err), maps:get(provider_message, Err)),
    ?assertEqual([cause, code, message, provider_message], lists:sort(maps:keys(Err))),
    %% No base64 body line of the private key appears anywhere in the error.
    Printed = iolist_to_binary(io_lib:format("~p", [Err])),
    [?assertEqual(nomatch, binary:match(Printed, Line)) || Line <- ?K:pem_body_lines(Pem)],
    ok.

fcm_signing_failure_does_not_leak_private_key_test() ->
    %% EC key handed to FCM (which expects RSA).
    Pem = ?K:ec_pem(),
    {C, P} = fcm(Pem),
    assert_no_key_leak(?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}), Pem, <<"FCM">>),
    %% Signing failed before the token exchange — no HTTP request was made.
    ?assertEqual([], ?F:calls(P)).

apns_signing_failure_does_not_leak_private_key_test() ->
    %% RSA key handed to APNs (which expects EC P-256).
    Pem = ?K:rsa_pem(),
    {C, P} = apns(Pem),
    assert_no_key_leak(?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}), Pem, <<"APNs">>),
    ?assertEqual([], ?F:calls(P)).

fcm_truncated_key_is_connector_error_test() ->
    Pem = truncated_pkcs8(),
    {C, P} = fcm(Pem),
    assert_no_key_leak(?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}), Pem, <<"FCM">>),
    ?assertEqual([], ?F:calls(P)).

apns_truncated_key_is_connector_error_test() ->
    Pem = truncated_pkcs8(),
    {C, P} = apns(Pem),
    assert_no_key_leak(?N:send_push(C, #{to => <<"devtok">>, body => <<"hi">>}), Pem, <<"APNs">>),
    ?assertEqual([], ?F:calls(P)).

%% Erlang-specific: a PKCS#1 RSA key and a non-P-256 EC key on APNs, a SEC1 EC
%% key on FCM, garbage, an empty-bodied PEM and an empty value — every failure
%% stays a typed auth_failed carrying only the kind.
other_bad_keys_test_() ->
    [
        ?_test(begin
            {C, P} = Mk(Pem),
            assert_no_key_leak(?N:send_push(C, #{to => <<"devtok">>}), Pem, Name),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Mk, Name, Pem} <- [
            {fun apns/1, <<"APNs">>, ?K:rsa_pem(pkcs1)},
            {fun apns/1, <<"APNs">>, ?K:p384_pem()},
            {fun fcm/1, <<"FCM">>, ?K:ec_pem(sec1)},
            {fun fcm/1, <<"FCM">>, <<"not a key">>},
            {fun apns/1, <<"APNs">>, ?K:armored(<<>>)},
            {fun fcm/1, <<"FCM">>, <<>>}
        ]
    ].
