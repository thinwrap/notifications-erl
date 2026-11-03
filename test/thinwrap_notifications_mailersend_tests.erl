-module(thinwrap_notifications_mailersend_tests).

%% Ported from the Python sibling's tests/test_mailersend.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(#{provider => mailersend, api_token => <<"k">>, from => <<"a@b.com">>}, Extra),
        Responses
    ).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

ok(Id) -> ?F:resp(202, <<>>, #{<<"X-Message-Id">> => Id}).

send_success_test() ->
    {C, P} = cfg(
        #{api_token => <<"mlsn.k">>, from => <<"from@acme.com">>, sender_name => <<"Acme">>}, [
            ok(<<"ms-123">>)
        ]
    ),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        text => <<"hello">>,
        html => <<"<b>hi</b>">>,
        cc => [<<"cc@x.com">>],
        bcc => [<<"bcc@x.com">>],
        reply_to => <<"reply@acme.com">>,
        headers => #{<<"X-Custom">> => <<"v">>},
        tags => [<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>, <<"f">>]
    }),
    ?assertEqual(
        #{
            success => true,
            status => queued,
            provider_message_id => <<"ms-123">>,
            raw => #{<<"messageId">> => <<"ms-123">>}
        },
        R
    ),
    Req = ?F:last(P),
    ?assertEqual(<<"api.mailersend.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v1/email">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer mlsn.k">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(<<"XMLHttpRequest">>, ?F:header(Req, <<"X-Requested-With">>)),
    Body = ?F:body_json(Req),
    ?assertEqual(
        #{<<"email">> => <<"from@acme.com">>, <<"name">> => <<"Acme">>}, maps:get(<<"from">>, Body)
    ),
    ?assertEqual([#{<<"email">> => <<"user@example.com">>}], maps:get(<<"to">>, Body)),
    ?assertEqual([#{<<"email">> => <<"cc@x.com">>}], maps:get(<<"cc">>, Body)),
    ?assertEqual([#{<<"email">> => <<"bcc@x.com">>}], maps:get(<<"bcc">>, Body)),
    %% reply_to is a single {email, name} object
    ?assertEqual(#{<<"email">> => <<"reply@acme.com">>}, maps:get(<<"reply_to">>, Body)),
    %% headers reshape to [{name, value}]
    ?assertEqual(
        [#{<<"name">> => <<"X-Custom">>, <<"value">> => <<"v">>}], maps:get(<<"headers">>, Body)
    ),
    %% tags capped at 5 (first-5-wins)
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>], maps:get(<<"tags">>, Body)).

snake_case_passthrough_test() ->
    {C, P} = cfg(#{}, [ok(<<"m1">>)]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{body => #{<<"templateId">> => <<"abc">>, <<"sendAt">> => 123}}
    }),
    Body = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"abc">>, maps:get(<<"template_id">>, Body)),
    ?assertEqual(123, maps:get(<<"send_at">>, Body)).

error_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(
            422, <<"{\"message\":\"Validation failed\",\"errors\":{\"to.0.email\":[\"invalid\"]}}">>
        )
    ]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient, status := 422, provider_message := <<"Validation failed">>
        }},
        ?N:send_email(C, (email())#{to => <<"bad">>})
    ).

error_auth_test() ->
    {C, _} = cfg(#{api_token => <<"bad">>}, [?F:resp(401, <<"{\"message\":\"Unauthenticated\"}">>)]),
    ?assertMatch({error, #{code := auth_failed}}, ?N:send_email(C, email())).

error_table_test_() ->
    Cases = [
        {422, <<"{\"message\":\"x\",\"errors\":{\"from.email\":[\"bad\"]}}">>, invalid_recipient},
        {422, <<"{\"message\":\"x\",\"errors\":{\"reply_to.email\":[\"bad\"]}}">>,
            invalid_recipient},
        {422, <<"{\"message\":\"x\",\"errors\":{\"subject\":[\"bad\"]}}">>, invalid_request},
        {422, <<"{\"message\":\"The recipient is invalid\"}">>, invalid_recipient},
        {422, <<"{\"message\":\"nope\"}">>, invalid_request},
        {400, <<"{}">>, invalid_request},
        {403, <<"{}">>, auth_failed},
        {429, <<"{}">>, rate_limited},
        {500, <<"{}">>, provider_unavailable},
        {404, <<"{}">>, unknown}
    ],
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, B)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {S, B, Want} <- Cases
    ].

all_suppressed_202_is_invalid_recipient_test() ->
    %% ALL_SUPPRESSED: 202 without X-Message-Id; "Email is not sent".
    Body = json:encode(#{
        <<"message">> => <<"There are some warnings for your request.">>,
        <<"warnings">> => [
            #{
                <<"type">> => <<"ALL_SUPPRESSED">>,
                <<"warning">> =>
                    <<"None of the recipients were sent this email because they are all suppressed.">>,
                <<"recipients">> => [
                    #{
                        <<"email">> => <<"suppressed@recipient.com">>,
                        <<"name">> => <<"Suppressed">>,
                        <<"reasons">> => [<<"hard_bounced">>]
                    }
                ]
            }
        ]
    }),
    {C, _} = cfg(#{}, [?F:resp(202, Body)]),
    {error, E} = ?N:send_email(C, (email())#{to => <<"suppressed@recipient.com">>}),
    ?assertMatch(#{code := invalid_recipient, status := 202}, E),
    #{cause := #{<<"raw">> := #{<<"warnings">> := [W]}}} = E,
    ?assertEqual(<<"ALL_SUPPRESSED">>, maps:get(<<"type">>, W)).

all_suppressed_without_message_uses_placeholder_test() ->
    {C, _} = cfg(#{}, [?F:resp(202, <<"{\"warnings\":[{\"type\":\"ALL_SUPPRESSED\"}]}">>)]),
    ?assertMatch(
        {error, #{message := <<"MailerSend suppressed all recipients; email not sent">>}},
        ?N:send_email(C, email())
    ).

some_suppressed_202_is_success_with_warnings_in_raw_test() ->
    Body = json:encode(#{
        <<"message">> => <<"There are some warnings for your request.">>,
        <<"warnings">> => [
            #{
                <<"type">> => <<"SOME_SUPPRESSED">>,
                <<"recipients">> => [#{<<"email">> => <<"suppressed@recipient.com">>}]
            }
        ]
    }),
    {C, _} = cfg(#{}, [?F:resp(202, Body, #{<<"x-message-id">> => <<"ms-456">>})]),
    {ok, R} = ?N:send_email(C, (email())#{bcc => [<<"suppressed@recipient.com">>]}),
    ?assertMatch(#{success := true, status := queued, provider_message_id := <<"ms-456">>}, R),
    Raw = maps:get(raw, R),
    ?assertEqual(<<"ms-456">>, maps:get(<<"messageId">>, Raw)),
    [W] = maps:get(<<"warnings">>, Raw),
    ?assertEqual(<<"SOME_SUPPRESSED">>, maps:get(<<"type">>, W)),
    ?assertMatch([#{<<"email">> := <<"suppressed@recipient.com">>}], maps:get(<<"recipients">>, W)).

attachment_has_no_content_type_field_test() ->
    %% MailerSend attachments: content, filename, disposition, id — no
    %% content-type field.
    {C, P} = cfg(#{}, [ok(<<"ms-1">>)]),
    {ok, _} = ?N:send_email(C, (email())#{
        attachments => [
            #{filename => <<"a.pdf">>, content => <<"pdf">>, content_type => <<"application/pdf">>},
            #{filename => <<"logo.png">>, content => <<"png">>, content_id => <<"logo">>}
        ]
    }),
    ?assertEqual(
        [
            #{<<"filename">> => <<"a.pdf">>, <<"content">> => <<"cGRm">>},
            #{
                <<"filename">> => <<"logo.png">>,
                <<"content">> => <<"cG5n">>,
                <<"id">> => <<"logo">>,
                <<"disposition">> => <<"inline">>
            }
        ],
        maps:get(<<"attachments">>, ?F:body_json(?F:last(P)))
    ).
