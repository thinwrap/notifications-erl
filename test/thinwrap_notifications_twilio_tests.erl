-module(thinwrap_notifications_twilio_tests).

%% The Python sibling has no test_twilio.py: its Twilio cases live in
%% test_core.py (golden send, regions/edges, form values, path escaping) and
%% test_request_guards.py (encoding, vendor numbers). Ported from those.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(201, <<"{\"sid\":\"SM1\"}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => twilio,
                account_sid => <<"AC1">>,
                auth_token => <<"tok">>,
                from => <<"+1">>
            },
            Extra
        ),
        Responses
    ).

sms() -> #{to => <<"+2">>, body => <<"hi">>}.

golden_send_and_region_and_media_test() ->
    {C, P} = cfg(#{region => <<"ie1">>}, [
        ?F:resp(201, <<"{\"sid\":\"SM1\",\"status\":\"queued\"}">>)
    ]),
    {ok, R} = ?N:send_sms(C, (sms())#{
        passthrough => #{body => #{<<"mediaUrl">> => [<<"u1">>, <<"u2">>]}}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"SM1">>}, R),
    ?assertEqual(#{<<"sid">> => <<"SM1">>, <<"status">> => <<"queued">>}, maps:get(raw, R)),
    Req = ?F:last(P),
    %% Twilio: "The edge location name (dublin, sydney) is a required part of
    %% the hostname for non-US regions"; api.ie1.twilio.com stopped working
    %% 2026-04-28.
    ?assertEqual(<<"api.dublin.ie1.twilio.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/2010-04-01/Accounts/AC1/Messages.json">>, ?F:path_of(Req)),
    ?assertEqual(
        <<"Basic ", (base64:encode(<<"AC1:tok">>))/binary>>, ?F:header(Req, <<"Authorization">>)
    ),
    ?assertEqual(<<"application/x-www-form-urlencoded">>, ?F:header(Req, <<"Content-Type">>)),
    Form = ?F:body_form(Req),
    ?assertEqual([<<"+2">>], maps:get(<<"To">>, Form)),
    ?assertEqual([<<"hi">>], maps:get(<<"Body">>, Form)),
    ?assertEqual([<<"+1">>], maps:get(<<"From">>, Form)),
    ?assertEqual([<<"u1">>, <<"u2">>], maps:get(<<"MediaUrl">>, Form)),
    %% Field order is the connector's, passthrough fields appended.
    ?assertMatch(<<"To=%2B2&Body=hi&From=%2B1&MediaUrl=u1&MediaUrl=u2">>, maps:get(body, Req)).

requires_sender_test() ->
    {C, P} = cfg(#{from => <<>>}, [?F:resp(201, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    ?assertEqual([], ?F:calls(P)),
    %% An empty MessagingServiceSid names no service.
    ?assertMatch(
        {error, #{code := invalid_request}},
        ?N:send_sms(C, (sms())#{passthrough => #{body => #{<<"MessagingServiceSid">> => <<>>}}})
    ).

messaging_service_sid_replaces_sender_test() ->
    %% A camelCase key is recased before the check, so it counts too.
    {C, P} = cfg(#{from => <<>>}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{body => #{messagingServiceSid => <<"MG1">>}}
    }),
    Form = ?F:body_form_single(?F:last(P)),
    ?assertEqual(<<"MG1">>, maps:get(<<"MessagingServiceSid">>, Form)),
    ?assertNot(maps:is_key(<<"From">>, Form)).

per_send_from_overrides_config_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{from => <<"+9">>}),
    ?assertEqual(<<"+9">>, maps:get(<<"From">>, ?F:body_form_single(?F:last(P)))).

%% --- Twilio REST regions + edges ------------------------------------------
%% https://www.twilio.com/docs/global-infrastructure/edge-locations/legacy-regions:
%% api.{region}.twilio.com "will stop working on April 28, 2026"; ie1 and au1
%% remain processing regions (api.dublin.ie1.twilio.com); br1/de1/jp1/sg1/us2
%% "process in US1 — use api.twilio.com".

region_edge_host_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(Extra, [?OK]),
            {ok, _} = ?N:send_sms(C, sms()),
            ?assertEqual(Host, ?F:host_of(?F:last(P)))
        end)
     || {Extra, Host} <- [
            {#{}, <<"api.twilio.com">>},
            {#{region => <<"us1">>}, <<"api.twilio.com">>},
            {#{region => <<"us1">>, edge => <<"ashburn">>}, <<"api.ashburn.us1.twilio.com">>},
            {#{region => <<"ie1">>}, <<"api.dublin.ie1.twilio.com">>},
            {#{region => <<"au1">>}, <<"api.sydney.au1.twilio.com">>},
            {#{region => <<"ie1">>, edge => <<"frankfurt">>}, <<"api.frankfurt.ie1.twilio.com">>},
            {#{edge => <<"tokyo">>}, <<"api.tokyo.us1.twilio.com">>}
        ]
    ].

bad_region_or_edge_rejected_before_sending_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(Extra, [?OK]),
            ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
            ?assertEqual([], ?F:calls(P))
        end)
     || Extra <- [
            #{region => <<"us2">>},
            #{region => <<"de1">>},
            #{region => <<"br1">>},
            #{region => <<"jp1">>},
            #{region => <<"sg1">>},
            #{region => <<"xx">>},
            #{region => <<"ie1">>, edge => <<"evil.com/">>},
            #{edge => <<"nowhere">>}
        ]
    ].

bad_region_and_edge_messages_test() ->
    {C, _} = cfg(#{region => <<"de1">>}, [?OK]),
    {error, #{message := M1}} = ?N:send_sms(C, sms()),
    ?assertMatch(<<"Unknown Twilio region: de1 (expected us1, ie1 or au1;", _/binary>>, M1),
    {C2, _} = cfg(#{edge => <<"nowhere">>}, [?OK]),
    {error, #{message := M2}} = ?N:send_sms(C2, sms()),
    ?assertEqual(
        <<
            "Unknown Twilio edge: nowhere (expected one of ashburn, dublin, frankfurt, roaming, "
            "sao-paulo, singapore, sydney, tokyo, umatilla)"
        >>,
        M2
    ).

%% --- form values, path escaping, encoding ------------------------------------

form_dict_value_is_json_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{body => #{<<"ContentVariables">> => #{<<"1">> => <<"Ada">>}}}
    }),
    ?assertEqual(
        [<<"{\"1\":\"Ada\"}">>], maps:get(<<"ContentVariables">>, ?F:body_form(?F:last(P)))
    ).

form_list_values_repeat_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{body => #{<<"MediaUrl">> => [<<"a">>, <<"b">>]}}
    }),
    ?assertEqual([<<"a">>, <<"b">>], maps:get(<<"MediaUrl">>, ?F:body_form(?F:last(P)))).

account_sid_path_segment_escaped_test() ->
    {C, P} = cfg(#{account_sid => <<"AC1/x">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, sms()),
    ?assertEqual(<<"/2010-04-01/Accounts/AC1%2Fx/Messages.json">>, ?F:path_of(?F:last(P))).

%% The Erlang analogue of the lone-surrogate case: not valid UTF-8.
invalid_utf8_is_invalid_request_test() ->
    {C, P} = cfg(#{}, [?OK]),
    ?assertMatch(
        {error, #{code := invalid_request, cause := #{<<"raw">> := #{<<"exception">> := _}}}},
        ?N:send_sms(C, (sms())#{body => <<"hi", 16#ff>>})
    ),
    ?assertEqual([], ?F:calls(P)).

pascal_casing_top_level_only_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{
            body => #{
                status_callback => <<"https://cb">>,
                <<"contentVariables">> => #{<<"firstName">> => <<"Ada">>}
            }
        }
    }),
    Form = ?F:body_form_single(?F:last(P)),
    ?assertEqual(<<"https://cb">>, maps:get(<<"StatusCallback">>, Form)),
    %% Nested keys are the caller's data and ride verbatim.
    ?assertEqual(<<"{\"firstName\":\"Ada\"}">>, maps:get(<<"ContentVariables">>, Form)).

%% --- error mapping -----------------------------------------------------------

error_table_test_() ->
    [
        ?_test(begin
            Body = iolist_to_binary(["{\"code\":", Code, ",\"message\":\"m\"}"]),
            {C, _} = cfg(#{}, [?F:resp(S, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := S, provider_message := <<"m">>}},
                ?N:send_sms(C, sms())
            )
        end)
     || {S, Code, Want} <- [
            {400, <<"21211">>, invalid_recipient},
            {400, <<"21408">>, invalid_recipient},
            {400, <<"21610">>, invalid_recipient},
            {400, <<"21612">>, invalid_recipient},
            {400, <<"21614">>, invalid_recipient},
            {400, <<"21614.0">>, invalid_recipient},
            {400, <<"20003">>, auth_failed},
            {400, <<"21606">>, invalid_request},
            {400, <<"null">>, invalid_request},
            {401, <<"20003">>, auth_failed},
            {403, <<"0">>, auth_failed},
            {404, <<"20404">>, invalid_request},
            {422, <<"21211">>, invalid_request},
            {429, <<"20429">>, rate_limited},
            {503, <<"0">>, provider_unavailable},
            {302, <<"0">>, unknown}
        ]
    ].

error_without_message_test() ->
    {C, _} = cfg(#{}, [?F:resp(400, <<"oops">>)]),
    ?assertMatch(
        {error, #{code := invalid_request, provider_message := <<"Twilio HTTP error">>}},
        ?N:send_sms(C, sms())
    ).

%% test_request_guards.py's NaN code: OTP's decoder rejects the NaN token, so
%% the body is null and the status decides.
nan_code_does_not_raise_raw_test() ->
    {C, _} = cfg(#{}, [?F:resp(400, <<"{\"code\":NaN,\"message\":\"x\"}">>)]),
    ?assertMatch(
        {error, #{code := invalid_request, cause := #{<<"raw">> := null}}}, ?N:send_sms(C, sms())
    ).
