-module(thinwrap_notifications_mailtrap_tests).

%% Ported from the Python sibling's tests/test_mailtrap.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(200, <<"{\"success\":true,\"message_ids\":[\"m\"]}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => mailtrap,
                api_token => <<"tok">>,
                mode => <<"production">>,
                from => <<"a@b.com">>
            },
            Extra
        ),
        Responses
    ).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

production_send_success_test() ->
    {C, P} = cfg(#{from => <<"from@acme.com">>, sender_name => <<"Acme">>}, [
        ?F:resp(200, <<"{\"success\":true,\"message_ids\":[\"mt-1\"]}">>)
    ]),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        text => <<"hello">>,
        html => <<"<b>hi</b>">>,
        reply_to => <<"reply@acme.com">>,
        cc => [<<"c@x.com">>],
        bcc => [<<"b@x.com">>],
        headers => #{<<"X-Custom">> => <<"v">>}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"mt-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"send.api.mailtrap.io">>, ?F:host_of(Req)),
    ?assertEqual(<<"/api/send">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer tok">>, ?F:header(Req, <<"Authorization">>)),
    Body = ?F:body_json(Req),
    ?assertEqual(
        #{<<"email">> => <<"from@acme.com">>, <<"name">> => <<"Acme">>}, maps:get(<<"from">>, Body)
    ),
    ?assertEqual([#{<<"email">> => <<"user@example.com">>}], maps:get(<<"to">>, Body)),
    ?assertEqual([#{<<"email">> => <<"c@x.com">>}], maps:get(<<"cc">>, Body)),
    ?assertEqual([#{<<"email">> => <<"b@x.com">>}], maps:get(<<"bcc">>, Body)),
    %% reply_to is a single object (not an array)
    ?assertEqual(#{<<"email">> => <<"reply@acme.com">>}, maps:get(<<"reply_to">>, Body)),
    %% headers are a flat map
    ?assertEqual(#{<<"X-Custom">> => <<"v">>}, maps:get(<<"headers">>, Body)).

attachments_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        attachments => [
            #{
                filename => <<"logo.png">>,
                content => <<"png">>,
                content_type => <<"image/png">>,
                content_id => <<"logo">>
            },
            #{filename => <<"a.txt">>, content => <<"a">>}
        ]
    }),
    ?assertEqual(
        [
            #{
                <<"filename">> => <<"logo.png">>,
                <<"content">> => <<"cG5n">>,
                <<"type">> => <<"image/png">>,
                <<"content_id">> => <<"logo">>,
                <<"disposition">> => <<"inline">>
            },
            #{<<"filename">> => <<"a.txt">>, <<"content">> => <<"YQ==">>}
        ],
        maps:get(<<"attachments">>, ?F:body_json(?F:last(P)))
    ).

sandbox_embeds_inbox_in_path_test() ->
    {C, P} = cfg(#{mode => <<"sandbox">>, inbox_id => <<"99">>}, [
        ?F:resp(200, <<"{\"message_ids\":[\"s1\"]}">>)
    ]),
    {ok, #{provider_message_id := <<"s1">>}} = ?N:send_email(C, email()),
    ?assertEqual(<<"sandbox.api.mailtrap.io">>, ?F:host_of(?F:last(P))),
    ?assertEqual(<<"/api/send/99">>, ?F:path_of(?F:last(P))).

snake_case_passthrough_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{
            body => #{
                <<"templateUuid">> => <<"abc">>, <<"customVariables">> => #{<<"k">> => <<"v">>}
            }
        }
    }),
    Body = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"abc">>, maps:get(<<"template_uuid">>, Body)),
    ?assertEqual(#{<<"k">> => <<"v">>}, maps:get(<<"custom_variables">>, Body)).

preflight_test_() ->
    %% No transport call is made — validation happens at send start.
    Cases = [
        {"mode required", #{mode => <<>>}, email(),
            <<"Mailtrap config.Mode must be 'sandbox' or 'production'; got \"\"">>},
        {"mode unknown", #{mode => <<"live">>}, email(),
            <<"Mailtrap config.Mode must be 'sandbox' or 'production'; got \"live\"">>},
        {"sandbox requires inbox", #{mode => <<"sandbox">>}, email(),
            <<"Mailtrap sandbox mode requires inboxId in config">>},
        {"production forbids inbox", #{inbox_id => <<"1">>}, email(),
            <<"Mailtrap production mode forbids inboxId in config (it is sandbox-only)">>},
        {"tags rejected", #{}, (email())#{tags => [<<"x">>]},
            <<"Mailtrap does not support tags at v1.0; use _passthrough.body.category instead">>}
    ],
    [
        {Name,
            ?_test(begin
                {C, P} = cfg(Extra, [?F:resp(200, <<"{}">>)]),
                ?assertMatch(
                    {error, #{code := invalid_request, message := Msg}}, ?N:send_email(C, I)
                ),
                ?assertEqual([], ?F:calls(P))
            end)}
     || {Name, Extra, I, Msg} <- Cases
    ].

mode_absent_is_preflight_error_test() ->
    {C, _} = ?F:config(#{provider => mailtrap, api_token => <<"k">>}, []),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_email(C, email())).

error_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [?F:resp(400, <<"{\"errors\":[\"'to' address is invalid recipient\"]}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient, provider_message := <<"'to' address is invalid recipient">>
        }},
        ?N:send_email(C, (email())#{to => <<"bad">>})
    ).

error_table_test_() ->
    Cases = [
        {401, <<"{}">>, auth_failed},
        {429, <<"{}">>, rate_limited},
        {500, <<"{}">>, provider_unavailable},
        {422, <<"{\"errors\":[\"subject is missing\",\"from address is invalid\"]}">>,
            invalid_recipient},
        {422, <<"{\"errors\":[\"subject is missing\"]}">>, invalid_request},
        {404, <<"{}">>, unknown}
    ],
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, B)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {S, B, Want} <- Cases
    ].

errors_joined_into_message_test() ->
    {C, _} = cfg(#{}, [?F:resp(422, <<"{\"errors\":[\"a\",\"b\"]}">>)]),
    ?assertMatch({error, #{provider_message := <<"a; b">>}}, ?N:send_email(C, email())).

sandbox_inbox_id_is_path_escaped_test() ->
    {C, P} = cfg(#{mode => <<"sandbox">>, inbox_id => <<"99/../x?y">>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(<<"sandbox.api.mailtrap.io">>, ?F:host_of(?F:last(P))),
    ?assertEqual(<<"/api/send/99%2F..%2Fx%3Fy">>, ?F:path_of(?F:last(P))).

empty_success_body_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<>>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>, raw := #{}}}, ?N:send_email(C, email())).
