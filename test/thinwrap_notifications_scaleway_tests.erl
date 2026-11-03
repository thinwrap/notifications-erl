-module(thinwrap_notifications_scaleway_tests).

%% Ported from the Python sibling's tests/test_scaleway.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(200, <<"{\"emails\":[{\"message_id\":\"m\"}]}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => scaleway,
                secret_key => <<"k">>,
                project_id => <<"p">>,
                from => <<"a@b.com">>
            },
            Extra
        ),
        Responses
    ).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

send_success_default_region_test() ->
    {C, P} = cfg(
        #{
            secret_key => <<"scw-secret">>,
            project_id => <<"proj-1">>,
            from => <<"from@acme.com">>,
            sender_name => <<"Acme">>
        },
        [?F:resp(200, <<"{\"emails\":[{\"message_id\":\"sw-1\"}]}">>)]
    ),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        text => <<"hello">>,
        html => <<"<b>hi</b>">>,
        cc => [<<"c@x.com">>],
        bcc => [<<"b@x.com">>],
        reply_to => <<"reply@acme.com">>,
        headers => #{<<"X-Custom">> => <<"v">>}
    }),
    ?assertMatch(#{success := true, status := queued, provider_message_id := <<"sw-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"api.scaleway.com">>, ?F:host_of(Req)),
    %% region interpolated into the PATH (default fr-par)
    ?assertEqual(<<"/transactional-email/v1alpha1/regions/fr-par/emails">>, ?F:path_of(Req)),
    ?assertEqual(<<"scw-secret">>, ?F:header(Req, <<"X-Auth-Token">>)),
    Body = ?F:body_json(Req),
    ?assertEqual(
        #{<<"email">> => <<"from@acme.com">>, <<"name">> => <<"Acme">>}, maps:get(<<"from">>, Body)
    ),
    ?assertEqual(<<"proj-1">>, maps:get(<<"project_id">>, Body)),
    ?assertEqual([#{<<"email">> => <<"c@x.com">>}], maps:get(<<"cc">>, Body)),
    ?assertEqual([#{<<"email">> => <<"b@x.com">>}], maps:get(<<"bcc">>, Body)),
    %% reply_to folded into additional_headers as a Reply-To entry (first)
    ?assertEqual(
        [
            #{<<"key">> => <<"Reply-To">>, <<"value">> => <<"reply@acme.com">>},
            #{<<"key">> => <<"X-Custom">>, <<"value">> => <<"v">>}
        ],
        maps:get(<<"additional_headers">>, Body)
    ).

region_in_path_test() ->
    {C, P} = cfg(#{region => <<"nl-ams">>}, [?F:resp(200, <<"{\"emails\":[{\"id\":\"x\"}]}">>)]),
    {ok, #{provider_message_id := <<"x">>}} = ?N:send_email(C, email()),
    ?assertEqual(<<"/transactional-email/v1alpha1/regions/nl-ams/emails">>, ?F:path_of(?F:last(P))).

attachment_default_mime_and_dropped_features_test() ->
    {C, P} = cfg(#{}, [?OK]),
    Att = #{filename => <<"f.bin">>, content => <<"x">>, content_id => <<"cid1">>},
    {ok, _} = ?N:send_email(C, (email())#{tags => [<<"dropped">>], attachments => [Att]}),
    Body = ?F:body_json(?F:last(P)),
    %% empty content_type -> default octet-stream; content_id has no field
    ?assertEqual(
        [
            #{
                <<"name">> => <<"f.bin">>,
                <<"type">> => <<"application/octet-stream">>,
                <<"content">> => <<"eA==">>
            }
        ],
        maps:get(<<"attachments">>, Body)
    ),
    %% tags dropped silently (no Scaleway field)
    ?assertNot(maps:is_key(<<"tags">>, Body)).

snake_case_passthrough_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{body => #{<<"scheduledAt">> => <<"2026-01-01T00:00:00Z">>}}
    }),
    ?assertEqual(
        <<"2026-01-01T00:00:00Z">>, maps:get(<<"scheduled_at">>, ?F:body_json(?F:last(P)))
    ).

error_auth_test() ->
    {C, _} = cfg(#{secret_key => <<"bad">>}, [?F:resp(403, <<"{\"message\":\"denied\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, provider_message := <<"denied">>}}, ?N:send_email(C, email())
    ).

error_400_invalid_request_test() ->
    {C, _} = cfg(#{}, [?F:resp(400, <<"{\"message\":\"bad request\"}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_email(C, email())).

error_message_falls_back_to_errors_list_test() ->
    {C, _} = cfg(#{}, [?F:resp(422, <<"{\"errors\":[{\"message\":\"first\"}]}">>)]),
    ?assertMatch(
        {error, #{code := invalid_request, provider_message := <<"first">>}},
        ?N:send_email(C, email())
    ).

error_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{}">>)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {S, Want} <- [
            {401, auth_failed}, {429, rate_limited}, {500, provider_unavailable}, {302, unknown}
        ]
    ].

region_validated_before_sending_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{region => Region}, [?F:resp(200, <<"{\"emails\":[]}">>)]),
            ?assertMatch({error, #{code := invalid_request}}, ?N:send_email(C, email())),
            ?assertEqual([], ?F:calls(P))
        end)
     || Region <- [<<"fr-par/../x">>, <<"FR-PAR">>, <<"fr_par">>, <<"x?y">>, <<"fr-par\n">>]
    ].

region_error_message_test() ->
    {C, _} = cfg(#{region => <<"x?y">>}, []),
    ?assertMatch(
        {error, #{message := <<"Invalid Scaleway region 'x?y'; expected an id such as 'fr-par'.">>}},
        ?N:send_email(C, email())
    ).

empty_success_body_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<>>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>, raw := #{}}}, ?N:send_email(C, email())).
