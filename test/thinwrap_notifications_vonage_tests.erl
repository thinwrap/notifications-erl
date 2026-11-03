-module(thinwrap_notifications_vonage_tests).

%% Ported from the Python sibling's tests/test_vonage.py, plus the Vonage case
%% of test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(200, <<"{\"messages\":[{\"status\":\"0\",\"message-id\":\"m\"}]}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(#{provider => vonage, api_key => <<"K">>, api_secret => <<"S">>}, Extra),
        Responses
    ).

sms() -> #{to => <<"+1">>, body => <<"b">>}.

send_form_and_passthrough_test() ->
    {C, P} = cfg(
        #{api_key => <<"KEY">>, api_secret => fun() -> <<"SECRET">> end, from => <<"Acme">>},
        [?F:resp(200, <<"{\"messages\":[{\"status\":\"0\",\"message-id\":\"msg-1\"}]}">>)]
    ),
    {ok, R} = ?N:send_sms(C, #{
        to => <<"+15551230000">>,
        body => <<"hi there">>,
        passthrough => #{body => #{<<"status-report-req">> => 1, <<"client-ref">> => <<"ref-9">>}}
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"msg-1">>}, R),
    Req = ?F:last(P),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"rest.nexmo.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/sms/json">>, ?F:path_of(Req)),
    ?assertEqual(<<"application/x-www-form-urlencoded">>, ?F:header(Req, <<"Content-Type">>)),
    Form = ?F:body_form(Req),
    ?assertEqual([<<"KEY">>], maps:get(<<"api_key">>, Form)),
    ?assertEqual([<<"SECRET">>], maps:get(<<"api_secret">>, Form)),
    ?assertEqual([<<"Acme">>], maps:get(<<"from">>, Form)),
    ?assertEqual([<<"+15551230000">>], maps:get(<<"to">>, Form)),
    ?assertEqual([<<"hi there">>], maps:get(<<"text">>, Form)),
    %% passthrough keys ride as given (Vonage wire names).
    ?assertEqual([<<"1">>], maps:get(<<"status-report-req">>, Form)),
    ?assertEqual([<<"ref-9">>], maps:get(<<"client-ref">>, Form)).

per_send_from_overrides_config_test() ->
    {C, P} = cfg(#{from => <<"cfg">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{from => <<"override">>}),
    ?assertEqual([<<"override">>], maps:get(<<"from">>, ?F:body_form(?F:last(P)))).

requires_sender_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    ?assertEqual([], ?F:calls(P)).

soft_error_status_maps_code_test() ->
    %% HTTP 200 with a non-"0" status is the source of truth (soft error).
    {C, _} = cfg(#{from => <<"a">>}, [
        ?F:resp(200, <<"{\"messages\":[{\"status\":\"4\",\"error-text\":\"Bad credentials\"}]}">>)
    ]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 200, provider_message := <<"Bad credentials">>}},
        ?N:send_sms(C, sms())
    ).

soft_error_invalid_recipient_test() ->
    {C, _} = cfg(#{from => <<"a">>}, [
        ?F:resp(200, <<"{\"messages\":[{\"status\":\"7\",\"error-text\":\"Number barred\"}]}">>)
    ]),
    ?assertMatch({error, #{code := invalid_recipient}}, ?N:send_sms(C, sms())).

soft_error_table_test_() ->
    [
        ?_test(begin
            Body = iolist_to_binary(["{\"messages\":[{\"status\":\"", S, "\"}]}"]),
            {C, _} = cfg(#{from => <<"a">>}, [?F:resp(200, Body)]),
            {error, E} = ?N:send_sms(C, sms()),
            ?assertMatch(#{code := Want}, E),
            %% Without error-text the status itself is the message.
            ?assertEqual(<<"Vonage status ", S/binary>>, maps:get(provider_message, E))
        end)
     || {S, Want} <- [
            {<<"1">>, rate_limited},
            {<<"3">>, invalid_request},
            {<<"5">>, provider_unavailable},
            {<<"9">>, auth_failed},
            {<<"15">>, invalid_request},
            {<<"29">>, invalid_recipient},
            {<<"34">>, invalid_recipient},
            {<<"99">>, unknown},
            {<<>>, unknown}
        ]
    ].

missing_messages_is_unknown_test() ->
    {C, _} = cfg(#{from => <<"a">>}, [?F:resp(200, <<"{\"messages\":[]}">>)]),
    ?assertMatch(
        {error, #{
            code := unknown,
            status := 200,
            provider_message := <<"Vonage response missing `messages[0]`.">>,
            cause := #{<<"raw">> := #{<<"messages">> := []}}
        }},
        ?N:send_sms(C, sms())
    ),
    {C2, _} = cfg(#{from => <<"a">>}, [?F:resp(200, <<"not json">>)]),
    ?assertMatch(
        {error, #{code := unknown, cause := #{<<"raw">> := null}}}, ?N:send_sms(C2, sms())
    ).

http_error_test() ->
    {C, _} = cfg(#{from => <<"a">>}, [
        ?F:resp(429, <<"rate limited">>, #{<<"Retry-After">> => <<"3">>})
    ]),
    {error, E} = ?N:send_sms(C, sms()),
    ?assertMatch(#{code := rate_limited, status := 429, provider_message := <<"rate limited">>}, E),
    %% A non-2xx body is raw text, not the messages envelope.
    ?assertEqual(
        #{
            <<"raw">> => <<"rate limited">>,
            <<"retryAfter">> => <<"3">>,
            <<"retryAfterSeconds">> => 3
        },
        maps:get(cause, E)
    ).

http_status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{from => <<"a">>}, [?F:resp(S, <<>>)]),
            {error, E} = ?N:send_sms(C, sms()),
            ?assertMatch(#{code := Want}, E),
            ?assertEqual(
                <<"Vonage HTTP ", (integer_to_binary(S))/binary>>, maps:get(provider_message, E)
            )
        end)
     || {S, Want} <- [
            {401, auth_failed},
            {403, auth_failed},
            {500, provider_unavailable},
            {400, invalid_request},
            {404, invalid_request},
            {302, unknown}
        ]
    ].

keys_as_given_test() ->
    {C, P} = cfg(#{from => <<"Acme">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{body => #{'client-ref' => <<"ref-1">>, <<"status-report-req">> => <<"1">>}}
    }),
    Form = ?F:body_form_single(?F:last(P)),
    ?assertEqual(<<"ref-1">>, maps:get(<<"client-ref">>, Form)),
    ?assertEqual(<<"1">>, maps:get(<<"status-report-req">>, Form)).
