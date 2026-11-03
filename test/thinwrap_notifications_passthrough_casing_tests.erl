-module(thinwrap_notifications_passthrough_casing_tests).

%% Passthrough casing. Most connectors send passthrough body keys exactly as
%% given, so the caller writes the vendor's own wire names. Seven connectors —
%% Postmark and Twilio (PascalCase); Mailtrap, SparkPost, SendGrid, MailerSend
%% and Scaleway (snake_case) — rewrite TOP-LEVEL keys only; nested maps always
%% ride verbatim. Ported from the email cases of the Python sibling's
%% tests/test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).

send(Cfg, Response, PtBody) ->
    {C, P} = ?F:config(Cfg, [Response]),
    {ok, _} = thinwrap_notifications:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"s">>,
        text => <<"t">>,
        passthrough => #{body => PtBody}
    }),
    ?F:body_json(?F:last(P)).

resend_keys_as_given_test() ->
    Payload = send(
        #{provider => resend, api_key => <<"re_k">>, from => <<"from@acme.com">>},
        ?F:resp(200, <<"{\"id\":\"re-1\"}">>),
        #{
            <<"scheduled_at">> => <<"in 1 min">>,
            <<"camelKey">> => 1,
            <<"headers">> => #{<<"X-Entity-Ref-ID">> => <<"123456789">>}
        }
    ),
    ?assertEqual(<<"in 1 min">>, maps:get(<<"scheduled_at">>, Payload)),
    ?assertEqual(1, maps:get(<<"camelKey">>, Payload)),
    ?assertNot(maps:is_key(<<"camel_key">>, Payload)),
    ?assertEqual(#{<<"X-Entity-Ref-ID">> => <<"123456789">>}, maps:get(<<"headers">>, Payload)).

ses_keys_as_given_test() ->
    Payload = send(
        #{
            provider => ses,
            region => <<"us-east-1">>,
            access_key_id => <<"AKID">>,
            secret_access_key => <<"s">>,
            from => <<"a@example.com">>
        },
        ?F:resp(200, <<"{\"MessageId\":\"m\"}">>),
        #{
            <<"ConfigurationSetName">> => <<"cs-1">>,
            <<"ListManagementOptions">> => #{
                <<"ContactListName">> => <<"news">>, <<"TopicName">> => <<"weekly">>
            }
        }
    ),
    ?assertEqual(<<"cs-1">>, maps:get(<<"ConfigurationSetName">>, Payload)),
    ?assertEqual(
        #{<<"ContactListName">> => <<"news">>, <<"TopicName">> => <<"weekly">>},
        maps:get(<<"ListManagementOptions">>, Payload)
    ).

brevo_keys_as_given_test() ->
    Payload = send(
        #{provider => brevo, api_key => <<"k">>, from => <<"a@b.com">>},
        ?F:resp(201, <<"{\"messageId\":\"m\"}">>),
        #{<<"scheduledAt">> => <<"x">>}
    ),
    ?assertEqual(<<"x">>, maps:get(<<"scheduledAt">>, Payload)).

postmark_top_level_pascal_nested_verbatim_test() ->
    Payload = send(
        #{provider => postmark, server_token => <<"tok">>, from => <<"from@acme.com">>},
        ?F:resp(200, <<"{\"MessageID\":\"m\",\"ErrorCode\":0}">>),
        #{trackOpens => true, metadata => #{orderId => <<"o-1">>}}
    ),
    ?assertEqual(true, maps:get(<<"TrackOpens">>, Payload)),
    ?assertEqual(#{<<"orderId">> => <<"o-1">>}, maps:get(<<"Metadata">>, Payload)).

%% A non-ASCII first letter is upper-cased as UTF-8, as the Python sibling's
%% `w[:1].upper()` does, not as a Latin-1 byte.
pascal_non_ascii_first_letter_test_() ->
    [
        ?_assertEqual(
            Want, thinwrap_notifications_casing:to_casing(Key, pascal)
        )
     || {Key, Want} <- [
            {<<"éclair_count"/utf8>>, <<"ÉclairCount"/utf8>>},
            {<<"ωmega"/utf8>>, <<"Ωmega"/utf8>>},
            {<<"e\x{301}tude"/utf8>>, <<"E\x{301}tude"/utf8>>},
            {<<"orderId">>, <<"OrderId">>}
        ]
    ].

mailtrap_top_level_snake_nested_verbatim_test() ->
    Payload = send(
        #{
            provider => mailtrap,
            api_token => <<"tok">>,
            mode => <<"production">>,
            from => <<"from@acme.com">>
        },
        ?F:resp(200, <<"{\"success\":true,\"message_ids\":[\"m\"]}">>),
        #{<<"customVariables">> => #{<<"userId">> => <<"u-1">>}}
    ),
    ?assertEqual(#{<<"userId">> => <<"u-1">>}, maps:get(<<"custom_variables">>, Payload)).

sparkpost_top_level_snake_nested_verbatim_test() ->
    Payload = send(
        #{provider => sparkpost, api_key => <<"k">>, from => <<"from@acme.com">>},
        ?F:resp(
            200,
            <<"{\"results\":{\"id\":\"t\",\"total_accepted_recipients\":1,\"total_rejected_recipients\":0}}">>
        ),
        #{<<"campaignId">> => <<"c-1">>, <<"substitutionData">> => #{<<"firstName">> => <<"Ada">>}}
    ),
    ?assertEqual(<<"c-1">>, maps:get(<<"campaign_id">>, Payload)),
    ?assertEqual(#{<<"firstName">> => <<"Ada">>}, maps:get(<<"substitution_data">>, Payload)).

scaleway_top_level_snake_test() ->
    Payload = send(
        #{
            provider => scaleway,
            secret_key => <<"k">>,
            project_id => <<"p">>,
            from => <<"a@b.com">>
        },
        ?F:resp(200, <<"{\"emails\":[]}">>),
        #{<<"scheduledAt">> => <<"x">>, <<"additionalHeaders">> => [#{<<"key">> => <<"K">>}]}
    ),
    ?assertEqual(<<"x">>, maps:get(<<"scheduled_at">>, Payload)),
    ?assertEqual([#{<<"key">> => <<"K">>}], maps:get(<<"additional_headers">>, Payload)).
