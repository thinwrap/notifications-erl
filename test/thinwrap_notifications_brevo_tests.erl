-module(thinwrap_notifications_brevo_tests).

%% Ported from the Python sibling's tests/test_brevo.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(#{provider => brevo, api_key => <<"k">>, from => <<"a@b.com">>}, Extra),
        Responses
    ).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

send_success_test() ->
    {C, P} = cfg(
        #{api_key => <<"xkeysib-1">>, from => <<"from@acme.com">>, sender_name => <<"Acme">>}, [
            ?F:resp(201, <<"{\"messageId\":\"br-1\"}">>)
        ]
    ),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        text => <<"hello">>,
        html => <<"<b>hi</b>">>,
        reply_to => <<"reply@acme.com">>,
        cc => [<<"cc@x.com">>],
        bcc => [<<"bcc@x.com">>],
        headers => #{<<"X-A">> => <<"1">>},
        tags => [<<"t1">>],
        attachments => [
            #{filename => <<"a.txt">>, content => <<"a">>, content_type => <<"text/plain">>}
        ]
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"br-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"api.brevo.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v3/smtp/email">>, ?F:path_of(Req)),
    %% api-key header (NOT Authorization: Bearer)
    ?assertEqual(<<"xkeysib-1">>, ?F:header(Req, <<"api-key">>)),
    ?assertEqual(undefined, ?F:header(Req, <<"Authorization">>)),
    Body = ?F:body_json(Req),
    %% camelCase wire; from -> sender, html -> htmlContent, text -> textContent
    ?assertEqual(
        #{<<"email">> => <<"from@acme.com">>, <<"name">> => <<"Acme">>},
        maps:get(<<"sender">>, Body)
    ),
    ?assertEqual([#{<<"email">> => <<"user@example.com">>}], maps:get(<<"to">>, Body)),
    ?assertEqual([#{<<"email">> => <<"cc@x.com">>}], maps:get(<<"cc">>, Body)),
    ?assertEqual([#{<<"email">> => <<"bcc@x.com">>}], maps:get(<<"bcc">>, Body)),
    ?assertEqual(<<"<b>hi</b>">>, maps:get(<<"htmlContent">>, Body)),
    ?assertEqual(<<"hello">>, maps:get(<<"textContent">>, Body)),
    ?assertEqual(#{<<"email">> => <<"reply@acme.com">>}, maps:get(<<"replyTo">>, Body)),
    ?assertEqual([<<"t1">>], maps:get(<<"tags">>, Body)),
    ?assertEqual(#{<<"X-A">> => <<"1">>}, maps:get(<<"headers">>, Body)),
    ?assertEqual(
        [#{<<"name">> => <<"a.txt">>, <<"content">> => <<"YQ==">>}],
        maps:get(<<"attachment">>, Body)
    ).

passthrough_verbatim_camelcase_test() ->
    {C, P} = cfg(#{}, [?F:resp(201, <<"{\"messageId\":\"m\"}">>)]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{
            body => #{<<"templateId">> => 7, <<"params">> => #{<<"name">> => <<"Sam">>}}
        }
    }),
    Body = ?F:body_json(?F:last(P)),
    %% No casing transform — forwarded verbatim.
    ?assertEqual(7, maps:get(<<"templateId">>, Body)),
    ?assertEqual(#{<<"name">> => <<"Sam">>}, maps:get(<<"params">>, Body)).

content_id_rejected_preflight_test() ->
    %% No HTTP call — contentId is rejected before any round-trip.
    {C, P} = cfg(#{}, [?F:resp(201, <<"{}">>)]),
    Att = #{
        filename => <<"logo.png">>,
        content => <<"x">>,
        content_type => <<"image/png">>,
        content_id => <<"logo">>
    },
    ?assertMatch(
        {error, #{code := invalid_request}}, ?N:send_email(C, (email())#{attachments => [Att]})
    ),
    ?assertEqual([], ?F:calls(P)).

error_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(
            400, <<"{\"code\":\"invalid_parameter\",\"message\":\"sender email is not valid\"}">>
        )
    ]),
    ?assertMatch({error, #{code := invalid_recipient}}, ?N:send_email(C, email())).

error_auth_test() ->
    {C, _} = cfg(#{api_key => <<"bad">>}, [?F:resp(401, <<"{\"message\":\"Key not found\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, provider_message := <<"Key not found">>}},
        ?N:send_email(C, email())
    ).

error_table_test_() ->
    Cases = [
        {402, auth_failed},
        {403, auth_failed},
        {429, rate_limited},
        {500, provider_unavailable},
        {400, invalid_request},
        {404, invalid_request},
        {409, unknown}
    ],
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{\"message\":\"bad\"}">>)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {S, Want} <- Cases
    ].
