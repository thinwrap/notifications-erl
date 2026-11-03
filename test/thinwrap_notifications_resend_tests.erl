-module(thinwrap_notifications_resend_tests).

%% Ported from the Python sibling's tests/test_resend.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(maps:merge(#{provider => resend, api_key => <<"re_k">>}, Extra), Responses).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

send_test() ->
    {C, P} = cfg(#{from => <<"from@acme.com">>, sender_name => <<"Acme">>}, [
        ?F:resp(200, <<"{\"id\":\"re-123\"}">>)
    ]),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        html => <<"<b>hi</b>">>,
        text => <<"hi">>,
        cc => [<<"cc@example.com">>]
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"re-123">>}, R),
    ?assertEqual(#{<<"id">> => <<"re-123">>}, maps:get(raw, R)),
    Req = ?F:last(P),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"api.resend.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/emails">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer re_k">>, ?F:header(Req, <<"Authorization">>)),
    Body = ?F:body_json(Req),
    ?assertEqual(<<"Acme <from@acme.com>">>, maps:get(<<"from">>, Body)),
    ?assertEqual([<<"user@example.com">>], maps:get(<<"to">>, Body)),
    ?assertEqual([<<"cc@example.com">>], maps:get(<<"cc">>, Body)),
    ?assertEqual(<<"<b>hi</b>">>, maps:get(<<"html">>, Body)),
    ?assertNot(maps:is_key(<<"bcc">>, Body)).

passthrough_keys_as_given_test() ->
    {C, P} = cfg(#{from => <<"from@acme.com">>}, [?F:resp(200, <<"{\"id\":\"m1\"}">>)]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{body => #{<<"scheduled_at">> => <<"2026-08-01T00:00:00Z">>}}
    }),
    ?assertEqual(
        <<"2026-08-01T00:00:00Z">>, maps:get(<<"scheduled_at">>, ?F:body_json(?F:last(P)))
    ).

error_mapping_test() ->
    {C, _} = cfg(#{from => <<"a@b.com">>}, [
        ?F:resp(
            422,
            <<"{\"name\":\"validation_error\",\"message\":\"Invalid `to` field: not a valid email address\"}">>
        )
    ]),
    ?assertMatch(
        {error, #{code := invalid_recipient, status := 422}},
        ?N:send_email(C, (email())#{to => <<"bad">>})
    ).

auth_error_mapping_test() ->
    {C, _} = cfg(#{api_key => <<"bad">>}, [?F:resp(401, <<"{\"message\":\"API key is invalid\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, provider_message := <<"API key is invalid">>}},
        ?N:send_email(C, email())
    ).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{\"message\":\"m\"}">>)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {S, Want} <- [
            {403, auth_failed},
            {429, rate_limited},
            {500, provider_unavailable},
            {404, invalid_request},
            {400, invalid_request},
            {409, unknown}
        ]
    ].

inline_attachment_carries_content_id_test() ->
    %% Resend send-email: attachments.content_id — "You can embed images using
    %% the content id parameter for the attachment".
    {C, P} = cfg(#{from => <<"from@acme.com">>}, [?F:resp(200, <<"{\"id\":\"m\"}">>)]),
    {ok, _} = ?N:send_email(C, #{
        to => <<"u@e.com">>,
        subject => <<"s">>,
        html => <<"<img src=\"cid:logo\">">>,
        tags => [<<"t1">>],
        reply_to => <<"r@x.com">>,
        headers => #{<<"X-Entity-Ref-ID">> => <<"1">>},
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
    Body = ?F:body_json(?F:last(P)),
    [A1, A2] = maps:get(<<"attachments">>, Body),
    ?assertEqual(
        #{
            <<"filename">> => <<"logo.png">>,
            <<"content">> => <<"cG5n">>,
            <<"content_type">> => <<"image/png">>,
            <<"content_id">> => <<"logo">>
        },
        A1
    ),
    ?assertEqual(#{<<"filename">> => <<"a.txt">>, <<"content">> => <<"YQ==">>}, A2),
    ?assertEqual([#{<<"name">> => <<"tag">>, <<"value">> => <<"t1">>}], maps:get(<<"tags">>, Body)),
    ?assertEqual(<<"r@x.com">>, maps:get(<<"reply_to">>, Body)),
    ?assertEqual(#{<<"X-Entity-Ref-ID">> => <<"1">>}, maps:get(<<"headers">>, Body)).

from_display_name_quoted_and_encoded_test() ->
    {C, P} = cfg(#{from => <<"from@acme.com">>, sender_name => <<"Acme, Inc.">>}, [
        ?F:resp(200, <<"{\"id\":\"m\"}">>)
    ]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(
        <<"\"Acme, Inc.\" <from@acme.com>">>, maps:get(<<"from">>, ?F:body_json(?F:last(P)))
    ),
    {C2, P2} = cfg(#{from => <<"from@acme.com">>, sender_name => <<"Café"/utf8>>}, [
        ?F:resp(200, <<"{\"id\":\"m\"}">>)
    ]),
    {ok, _} = ?N:send_email(C2, email()),
    ?assertEqual(
        <<"=?UTF-8?B?Q2Fmw6k=?= <from@acme.com>">>, maps:get(<<"from">>, ?F:body_json(?F:last(P2)))
    ).

non_json_success_body_is_null_raw_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<"not json">>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>, raw := null}}, ?N:send_email(C, email())).
