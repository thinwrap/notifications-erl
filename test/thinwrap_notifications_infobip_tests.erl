-module(thinwrap_notifications_infobip_tests).

%% Ported from the Python sibling's tests/test_infobip.py, plus the Infobip
%% case of test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => infobip,
                base_url => <<"b.api.infobip.com">>,
                api_key => <<"k">>,
                from => <<"A">>
            },
            Extra
        ),
        Responses
    ).

sms() -> #{to => <<"+1">>, body => <<"b">>}.

send_success_test() ->
    {C, P} = cfg(#{base_url => <<"xyz123.api.infobip.com">>, from => <<"Acme">>}, [
        ?F:resp(
            200,
            <<"{\"messages\":[{\"messageId\":\"MID-1\",\"status\":{\"name\":\"PENDING_ACCEPTED\"}}]}">>
        )
    ]),
    {ok, R} = ?N:send_sms(C, #{to => <<"+15551234567">>, body => <<"hi there">>}),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"MID-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"xyz123.api.infobip.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/sms/2/text/advanced">>, ?F:path_of(Req)),
    ?assertEqual(<<"App k">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Accept">>)),
    ?assertEqual(
        #{
            <<"messages">> => [
                #{
                    <<"from">> => <<"Acme">>,
                    <<"text">> => <<"hi there">>,
                    <<"destinations">> => [#{<<"to">> => <<"+15551234567">>}]
                }
            ]
        },
        ?F:body_json(Req)
    ).

passthrough_merges_verbatim_test() ->
    {C, P} = cfg(#{from => <<>>}, [?F:resp(200, <<"{\"messages\":[{\"messageId\":\"m\"}]}">>)]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        from => <<"Sender">>,
        passthrough => #{
            body => #{<<"bulkId">> => <<"BULK-9">>, includeSmsCountInResponse => true}
        }
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"BULK-9">>, maps:get(<<"bulkId">>, Payload)),
    ?assertEqual(true, maps:get(<<"includeSmsCountInResponse">>, Payload)).

requires_sender_test() ->
    {C, P} = cfg(#{from => <<>>}, [?F:resp(200, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    ?assertEqual([], ?F:calls(P)).

error_auth_test() ->
    Body =
        <<
            "{\"requestError\":{\"serviceException\":{\"messageId\":\"UNAUTHORIZED\","
            "\"text\":\"Invalid login details\"}}}"
        >>,
    {C, _} = cfg(#{api_key => <<"bad">>}, [?F:resp(401, Body)]),
    ?assertMatch(
        {error, #{
            code := auth_failed, status := 401, provider_message := <<"Invalid login details">>
        }},
        ?N:send_sms(C, sms())
    ).

error_rate_limited_test() ->
    {C, _} = cfg(#{}, [?F:resp(429, <<"{}">>, #{<<"Retry-After">> => <<"30">>})]),
    ?assertMatch(
        {error, #{
            code := rate_limited,
            provider_message := <<"Infobip HTTP 429">>,
            cause := #{<<"retryAfterSeconds">> := 30}
        }},
        ?N:send_sms(C, sms())
    ).

error_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, Body)]),
            ?assertMatch({error, #{code := Want, provider_message := Msg}}, ?N:send_sms(C, sms()))
        end)
     || {S, Body, Want, Msg} <- [
            {403, <<>>, auth_failed, <<"Infobip HTTP 403">>},
            {500, <<>>, provider_unavailable, <<"Infobip HTTP 500">>},
            {
                400,
                <<"{\"requestError\":{\"serviceException\":{\"messageId\":\"BAD_REQUEST\"}}}">>,
                invalid_request,
                <<"Infobip HTTP 400 BAD_REQUEST">>
            },
            {302, <<>>, unknown, <<"Infobip HTTP 302">>}
        ]
    ].

rejected(Name, Description) ->
    iolist_to_binary(
        json:encode(#{
            <<"bulkId">> => <<"B-1">>,
            <<"messages">> => [
                #{
                    <<"messageId">> => <<"MID-R">>,
                    <<"to">> => <<"+15551234567">>,
                    <<"status">> => #{
                        <<"groupId">> => 5,
                        <<"groupName">> => <<"REJECTED">>,
                        <<"id">> => 51,
                        <<"name">> => Name,
                        <<"description">> => Description
                    }
                }
            ]
        })
    ).

rejected_200_raises_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(200, rejected(Name, <<"Rejected">>))]),
            {error, E} = ?N:send_sms(C, (sms())#{to => <<"+15551234567">>}),
            ?assertMatch(#{code := Want, status := 200, provider_message := <<"Rejected">>}, E),
            #{<<"raw">> := #{<<"messages">> := [#{<<"status">> := St}]}} = maps:get(cause, E),
            ?assertEqual(Name, maps:get(<<"name">>, St))
        end)
     || {Name, Want} <- [
            {<<"REJECTED_DESTINATION">>, invalid_recipient},
            {<<"REJECTED_PREFIX_MISSING">>, invalid_recipient},
            {<<"MISSING_TO">>, invalid_recipient},
            {<<"REJECTED_DND">>, invalid_recipient},
            {<<"REJECTED_NOT_REGISTERED">>, invalid_recipient},
            {<<"REJECTED_FLOODING_FILTER">>, rate_limited},
            {<<"REJECTED_NOT_ENOUGH_CREDITS">>, invalid_request},
            {<<"REJECTED_SENDER">>, invalid_request}
        ]
    ].

rejected_200_by_group_name_only_test() ->
    Body =
        <<
            "{\"messages\":[{\"messageId\":\"m\",\"status\":{\"groupName\":\"rejected\","
            "\"name\":\"rejected_sender\"}}]}"
        >>,
    {C, _} = cfg(#{}, [?F:resp(200, Body)]),
    ?assertMatch(
        {error, #{code := invalid_request, provider_message := <<"REJECTED_SENDER">>}},
        ?N:send_sms(C, sms())
    ).

rejected_200_by_group_id_only_test() ->
    Body = <<"{\"messages\":[{\"messageId\":\"m\",\"status\":{\"groupId\":5.0}}]}">>,
    {C, _} = cfg(#{}, [?F:resp(200, Body)]),
    ?assertMatch(
        {error, #{code := invalid_request, provider_message := <<"Infobip rejected the message">>}},
        ?N:send_sms(C, sms())
    ).

pending_200_is_success_test() ->
    Body = iolist_to_binary(
        json:encode(#{
            <<"bulkId">> => <<"B-2">>,
            <<"messages">> => [
                #{
                    <<"messageId">> => <<"MID-P">>,
                    <<"to">> => <<"+15551234567">>,
                    <<"status">> => #{
                        <<"groupId">> => 1,
                        <<"groupName">> => <<"PENDING">>,
                        <<"id">> => 26,
                        <<"name">> => <<"PENDING_ACCEPTED">>,
                        <<"description">> => <<"Message sent to next instance">>
                    }
                }
            ]
        })
    ),
    {C, _} = cfg(#{}, [?F:resp(200, Body)]),
    ?assertMatch(
        {ok, #{success := true, provider_message_id := <<"MID-P">>}},
        ?N:send_sms(C, (sms())#{to => <<"+15551234567">>})
    ).

no_messages_is_empty_id_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<"{}">>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>}}, ?N:send_sms(C, sms())).

base_url_must_be_bare_hostname_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{base_url => BaseUrl}, [?F:resp(200, <<"{\"messages\":[]}">>)]),
            {error, E} = ?N:send_sms(C, sms()),
            ?assertMatch(#{code := invalid_request}, E),
            ?assertEqual([], ?F:calls(P)),
            case BaseUrl of
                <<>> ->
                    ok;
                _ ->
                    Text = iolist_to_binary(io_lib:format("~p", [E])),
                    ?assertEqual(nomatch, binary:match(Text, BaseUrl))
            end
        end)
     || BaseUrl <- [
            <<"https://xyz123.api.infobip.com">>,
            <<"xyz123.api.infobip.com/">>,
            <<"xyz123.api.infobip.com/sms">>,
            <<"xyz123.api.infobip.com:8443">>,
            <<"user:pw@evil.example">>,
            <<"evil.example?x=">>,
            <<"evil.example#">>,
            <<"-bad.api.infobip.com">>,
            <<"a..b">>,
            <<>>,
            <<"SECRET-TOKEN-VALUE/evil">>,
            %% test_request_guards.py: whole-string validators.
            <<"x.api.infobip.com\n">>,
            <<(binary:copy(<<"a.">>, 126))/binary, "ab">>
        ]
    ].
