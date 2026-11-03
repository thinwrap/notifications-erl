-module(thinwrap_notifications_sparkpost_tests).

%% Ported from the Python sibling's tests/test_sparkpost.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK,
    ?F:resp(
        200,
        <<"{\"results\":{\"id\":\"t\",\"total_accepted_recipients\":1,\"total_rejected_recipients\":0}}">>
    )
).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(#{provider => sparkpost, api_key => <<"k">>, from => <<"a@b.com">>}, Extra),
        Responses
    ).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

send_success_us_test() ->
    {C, P} = cfg(
        #{api_key => <<"raw-key">>, from => <<"from@acme.com">>, sender_name => <<"Acme">>}, [
            ?F:resp(
                200,
                <<"{\"results\":{\"id\":\"sp-1\",\"total_accepted_recipients\":2,\"total_rejected_recipients\":0}}">>
            )
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
        tags => [<<"t1">>]
    }),
    ?assertMatch(#{success := true, status := queued, provider_message_id := <<"sp-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"api.sparkpost.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/api/v1/transmissions">>, ?F:path_of(Req)),
    %% Raw key — no Bearer/Basic prefix.
    ?assertEqual(<<"raw-key">>, ?F:header(Req, <<"Authorization">>)),
    Body = ?F:body_json(Req),
    Content = maps:get(<<"content">>, Body),
    ?assertEqual(
        #{<<"email">> => <<"from@acme.com">>, <<"name">> => <<"Acme">>},
        maps:get(<<"from">>, Content)
    ),
    %% reply_to is a string
    ?assertEqual(<<"reply@acme.com">>, maps:get(<<"reply_to">>, Content)),
    %% CC visible via comma-joined header; BCC never a header
    ?assertEqual(#{<<"CC">> => <<"cc@x.com">>}, maps:get(<<"headers">>, Content)),
    %% recipients[] carries the primary To plus cc/bcc with header_to
    ?assertEqual(
        [
            #{<<"address">> => #{<<"email">> => <<"user@example.com">>}},
            #{
                <<"address">> => #{
                    <<"email">> => <<"cc@x.com">>, <<"header_to">> => <<"user@example.com">>
                }
            },
            #{
                <<"address">> => #{
                    <<"email">> => <<"bcc@x.com">>, <<"header_to">> => <<"user@example.com">>
                }
            }
        ],
        maps:get(<<"recipients">>, Body)
    ),
    ?assertEqual(#{<<"tags">> => [<<"t1">>]}, maps:get(<<"metadata">>, Body)).

eu_region_host_test() ->
    {C, P} = cfg(#{region => <<"eu">>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(<<"api.eu.sparkpost.com">>, ?F:host_of(?F:last(P))).

snake_case_passthrough_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{
            body => #{<<"campaignId">> => <<"camp">>, <<"substitutionData">> => #{<<"n">> => 1}}
        }
    }),
    Body = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"camp">>, maps:get(<<"campaign_id">>, Body)),
    ?assertEqual(#{<<"n">> => 1}, maps:get(<<"substitution_data">>, Body)).

all_rejected_is_invalid_recipient_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(
            200,
            <<"{\"results\":{\"id\":\"z\",\"total_accepted_recipients\":0,\"total_rejected_recipients\":1}}">>
        )
    ]),
    {error, E} = ?N:send_email(C, (email())#{to => <<"bad@x.com">>}),
    ?assertMatch(
        #{
            code := invalid_recipient,
            status := 200,
            message := <<"SparkPost rejected all recipients">>,
            provider_message := <<"total_rejected_recipients=1, total_accepted_recipients=0">>,
            cause := #{<<"raw">> := #{<<"results">> := _}}
        },
        E
    ).

error_auth_test() ->
    {C, _} = cfg(#{api_key => <<"bad">>}, [
        ?F:resp(401, <<"{\"errors\":[{\"message\":\"Unauthorized\"}]}">>)
    ]),
    ?assertMatch(
        {error, #{code := auth_failed, provider_message := <<"Unauthorized">>}},
        ?N:send_email(C, email())
    ).

error_400_recipient_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(
            400,
            <<"{\"errors\":[{\"message\":\"recipient address is invalid\",\"code\":\"1300\"}]}">>
        )
    ]),
    ?assertMatch(
        {error, #{code := invalid_recipient}}, ?N:send_email(C, (email())#{to => <<"bad">>})
    ).

error_table_test_() ->
    Cases = [
        {400, <<"{\"errors\":[{\"message\":\"bad\",\"code\":\"1301\"}]}">>, invalid_recipient},
        {400, <<"{\"errors\":[{\"message\":\"bad\",\"code\":\"1100\"}]}">>, invalid_request},
        {413, <<"{}">>, invalid_request},
        {422, <<"{}">>, invalid_request},
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

inline_image_name_is_content_id_and_type_required_test() ->
    %% Transmissions API: inline_images.name "will be inserted into the
    %% Content-ID header"; `type` is required on attachments and inline_images.
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, #{
        to => <<"u@e.com">>,
        subject => <<"s">>,
        html => <<"<img src=\"cid:logo\">">>,
        attachments => [
            #{
                filename => <<"logo.png">>,
                content => <<"png">>,
                content_type => <<"image/png">>,
                content_id => <<"logo">>
            },
            #{filename => <<"data.bin">>, content => <<"x">>}
        ]
    }),
    Content = maps:get(<<"content">>, ?F:body_json(?F:last(P))),
    ?assertEqual(
        [#{<<"name">> => <<"logo">>, <<"type">> => <<"image/png">>, <<"data">> => <<"cG5n">>}],
        maps:get(<<"inline_images">>, Content)
    ),
    ?assertEqual(
        [
            #{
                <<"name">> => <<"data.bin">>,
                <<"type">> => <<"application/octet-stream">>,
                <<"data">> => <<"eA==">>
            }
        ],
        maps:get(<<"attachments">>, Content)
    ).

rate_limit_420_test() ->
    %% "420 Exceed Sending Limit — You exceeded your daily, monthly, or sandbox
    %% sending limit."
    {C, _} = cfg(#{}, [?F:resp(420, <<"{\"errors\":[{\"message\":\"Exceed Sending Limit\"}]}">>)]),
    ?assertMatch({error, #{code := rate_limited}}, ?N:send_email(C, email())).
