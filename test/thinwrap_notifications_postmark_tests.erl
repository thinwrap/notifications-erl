-module(thinwrap_notifications_postmark_tests).

%% Ported from the Python sibling's tests/test_postmark.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(200, <<"{\"MessageID\":\"m\",\"ErrorCode\":0}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{provider => postmark, server_token => <<"tok">>, from => <<"from@acme.com">>}, Extra
        ),
        Responses
    ).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

send_test() ->
    {C, P} = cfg(#{sender_name => <<"Acme">>, message_stream => <<"outbound">>}, [
        ?F:resp(
            200,
            <<"{\"To\":\"user@example.com\",\"MessageID\":\"pm-123\",\"ErrorCode\":0,\"Message\":\"OK\"}">>
        )
    ]),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        html => <<"<b>hi</b>">>,
        text => <<"hi">>,
        cc => [<<"c1@example.com">>, <<"c2@example.com">>],
        bcc => [<<"b@example.com">>],
        reply_to => <<"r@acme.com">>,
        headers => #{<<"X-Custom">> => <<"v">>},
        tags => [<<"first">>, <<"second">>]
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"pm-123">>}, R),
    Req = ?F:last(P),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"api.postmarkapp.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/email">>, ?F:path_of(Req)),
    ?assertEqual(<<"tok">>, ?F:header(Req, <<"X-Postmark-Server-Token">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Accept">>)),
    Body = ?F:body_json(Req),
    ?assertEqual(<<"Acme <from@acme.com>">>, maps:get(<<"From">>, Body)),
    ?assertEqual(<<"c1@example.com, c2@example.com">>, maps:get(<<"Cc">>, Body)),
    ?assertEqual(<<"b@example.com">>, maps:get(<<"Bcc">>, Body)),
    ?assertEqual(<<"r@acme.com">>, maps:get(<<"ReplyTo">>, Body)),
    ?assertEqual(<<"outbound">>, maps:get(<<"MessageStream">>, Body)),
    %% Single-tag normalization: first tag wins.
    ?assertEqual(<<"first">>, maps:get(<<"Tag">>, Body)),
    %% Headers map -> [{Name, Value}].
    ?assertEqual(
        [#{<<"Name">> => <<"X-Custom">>, <<"Value">> => <<"v">>}], maps:get(<<"Headers">>, Body)
    ).

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
                <<"Name">> => <<"logo.png">>,
                <<"Content">> => <<"cG5n">>,
                <<"ContentType">> => <<"image/png">>,
                %% Postmark requires the cid: prefix in ContentID for inline images.
                <<"ContentID">> => <<"cid:logo">>
            },
            #{<<"Name">> => <<"a.txt">>, <<"Content">> => <<"YQ==">>}
        ],
        maps:get(<<"Attachments">>, ?F:body_json(?F:last(P)))
    ).

passthrough_pascal_case_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{body => #{<<"templateModel">> => #{<<"name">> => <<"Sam">>}}}
    }),
    ?assert(maps:is_key(<<"TemplateModel">>, ?F:body_json(?F:last(P)))).

embedded_error_on_200_test() ->
    %% Postmark returns 200 OK with ErrorCode != 0 on rejection.
    {C, _} = cfg(#{}, [
        ?F:resp(200, <<"{\"ErrorCode\":300,\"Message\":\"Invalid 'To' address: 'bad'.\"}">>)
    ]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient,
            status := 422,
            provider_message := <<"Invalid 'To' address: 'bad'.">>
        }},
        ?N:send_email(C, email())
    ).

http_error_mapping_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(422, <<"{\"ErrorCode\":405,\"Message\":\"Sender signature not confirmed\"}">>)
    ]),
    ?assertMatch({error, #{code := auth_failed}}, ?N:send_email(C, email())).

auth_error_mapping_test() ->
    {C, _} = cfg(#{server_token => <<"bad">>}, [
        ?F:resp(401, <<"{\"ErrorCode\":10,\"Message\":\"Bad or missing server token\"}">>)
    ]),
    ?assertMatch({error, #{code := auth_failed}}, ?N:send_email(C, email())).

%% ErrorCode table: https://postmarkapp.com/developer/api/overview#error-codes
error_code_table_test_() ->
    Cases = [
        {406, <<"Inactive recipient.">>, invalid_recipient},
        {411, <<"Attachment file type not allowed.">>, invalid_request},
        {412,
            <<"While your account is pending approval, all recipients must share the same domain as the From address.">>,
            auth_failed},
        {413, <<"This account is not approved to send email.">>, auth_failed},
        {300, <<"Invalid 'To' address: 'bad'.">>, invalid_recipient},
        {300, <<"Provide either email TextBody or HtmlBody or both.">>, invalid_request},
        {1235, <<"The message stream for the provided 'MessageStream' was not found.">>,
            invalid_request},
        {1480, <<"IP not authorized.">>, auth_failed}
    ],
    [
        ?_test(begin
            Body = json:encode(#{<<"ErrorCode">> => Code, <<"Message">> => Msg}),
            {C, _} = cfg(#{}, [?F:resp(422, Body)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {Code, Msg, Want} <- Cases
    ].

sender_name_with_comma_is_quoted_test() ->
    %% Postmark send guide: "\"Joe Receiver, Jr.\" <receiver@example.com>".
    {C, P} = cfg(#{from => <<"joe@acme.com">>, sender_name => <<"Joe Sender, Jr.">>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(
        <<"\"Joe Sender, Jr.\" <joe@acme.com>">>, maps:get(<<"From">>, ?F:body_json(?F:last(P)))
    ).

%% Templates API: POST /email/withTemplate, "TemplateId: Required if
%% TemplateAlias is not specified", TemplateModel "applied to the specified
%% template to generate HtmlBody, TextBody, and Subject".
template_routes_to_with_template_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{}, [?OK]),
            {ok, _} = ?N:send_email(C, #{
                to => <<"u@e.com">>,
                subject => <<"ignored">>,
                html => <<"<p>ignored</p>">>,
                text => <<"ignored">>,
                passthrough => #{body => PtBody}
            }),
            Req = ?F:last(P),
            ?assertEqual(<<"api.postmarkapp.com">>, ?F:host_of(Req)),
            ?assertEqual(<<"/email/withTemplate">>, ?F:path_of(Req)),
            Body = ?F:body_json(Req),
            [
                ?assertNot(maps:is_key(K, Body))
             || K <- [<<"Subject">>, <<"HtmlBody">>, <<"TextBody">>]
            ],
            ?assertEqual(<<"from@acme.com">>, maps:get(<<"From">>, Body)),
            ?assertEqual(<<"u@e.com">>, maps:get(<<"To">>, Body)),
            case PtBody of
                #{templateId := _} ->
                    ?assertEqual(1234567, maps:get(<<"TemplateId">>, Body)),
                    ?assertEqual(#{<<"name">> => <<"Sam">>}, maps:get(<<"TemplateModel">>, Body));
                _ ->
                    ?assertEqual(<<"welcome">>, maps:get(<<"TemplateAlias">>, Body)),
                    ?assertEqual(#{}, maps:get(<<"TemplateModel">>, Body))
            end
        end)
     || PtBody <- [
            #{templateId => 1234567, templateModel => #{<<"name">> => <<"Sam">>}},
            #{<<"TemplateAlias">> => <<"welcome">>}
        ]
    ].

without_template_uses_email_endpoint_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, #{to => <<"u@e.com">>, subject => <<"Hi">>, html => <<"<p>x</p>">>}),
    ?assertEqual(<<"/email">>, ?F:path_of(?F:last(P))),
    Body = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"Hi">>, maps:get(<<"Subject">>, Body)),
    ?assertEqual(<<"<p>x</p>">>, maps:get(<<"HtmlBody">>, Body)),
    ?assertNot(maps:is_key(<<"TemplateModel">>, Body)).

recipient_only_for_to_cc_bcc_address_test_() ->
    %% ErrorCode 300 "Send validation" covers "zero recipients, invalid
    %% address, missing TextBody/HtmlBody, and recipient, metadata, attachment,
    %% or header limits".
    Cases = [
        {<<"Zero recipients specified">>, invalid_request},
        {<<"Invalid 'From' address: 'bad'.">>, invalid_request},
        {<<"Error parsing 'Cc': Illegal email address 'x'. It must contain the '@' symbol.">>,
            invalid_recipient},
        {<<"Invalid 'Bcc' address: 'x'.">>, invalid_recipient},
        {<<"Provide either email TextBody or HtmlBody or both.">>, invalid_request}
    ],
    [
        ?_test(begin
            {C, _} = cfg(#{}, [
                ?F:resp(422, json:encode(#{<<"ErrorCode">> => 300, <<"Message">> => Msg}))
            ]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {Msg, Want} <- Cases
    ].

other_4xx_is_invalid_request_test_() ->
    %% HTTP status table: 404 missing resource, 413 over the size limit, 415
    %% missing request headers.
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{\"ErrorCode\":0,\"Message\":\"x\"}">>)]),
            ?assertMatch({error, #{code := invalid_request}}, ?N:send_email(C, email()))
        end)
     || S <- [404, 413, 415]
    ].

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{}">>)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {S, Want} <- [
            {403, auth_failed}, {429, rate_limited}, {503, provider_unavailable}, {302, unknown}
        ]
    ].

empty_alias_stays_on_email_and_null_model_becomes_object_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, #{
        to => <<"u@e.com">>,
        subject => <<"Hi">>,
        text => <<"t">>,
        passthrough => #{body => #{<<"TemplateAlias">> => <<>>}}
    }),
    ?assertEqual(<<"/email">>, ?F:path_of(?F:last(P))),
    ?assertEqual(<<"Hi">>, maps:get(<<"Subject">>, ?F:body_json(?F:last(P)))),
    {ok, _} = ?N:send_email(C, #{
        to => <<"u@e.com">>,
        subject => <<"Hi">>,
        text => <<"t">>,
        passthrough => #{body => #{<<"TemplateId">> => 7, <<"TemplateModel">> => null}}
    }),
    ?assertEqual(<<"/email/withTemplate">>, ?F:path_of(?F:last(P))),
    ?assertEqual(#{}, maps:get(<<"TemplateModel">>, ?F:body_json(?F:last(P)))).

empty_success_body_raw_is_empty_map_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<>>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>, raw := #{}}}, ?N:send_email(C, email())).
