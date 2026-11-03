-module(thinwrap_notifications_textmagic_tests).

%% Ported from the Python sibling's tests/test_textmagic.py, plus the
%% Textmagic cases of test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(#{provider => textmagic, username => <<"u">>, api_key => <<"k">>}, Extra),
        Responses
    ).

sms() -> #{to => <<"+1">>, body => <<"b">>}.

send_success_test() ->
    {C, P} = cfg(
        #{username => <<"user">>, api_key => fun() -> <<"apikey">> end, from => <<"447700">>},
        [
            ?F:resp(
                201, <<"{\"id\":34567,\"href\":\"/api/v2/messages/34567\",\"type\":\"message\"}">>
            )
        ]
    ),
    {ok, R} = ?N:send_sms(C, #{to => <<"+15551234567">>, body => <<"hi there">>}),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"34567">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"rest.textmagic.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/api/v2/messages">>, ?F:path_of(Req)),
    ?assertEqual(<<"user">>, ?F:header(Req, <<"X-TM-Username">>)),
    ?assertEqual(<<"apikey">>, ?F:header(Req, <<"X-TM-Key">>)),
    ?assertEqual(<<"application/x-www-form-urlencoded">>, ?F:header(Req, <<"Content-Type">>)),
    ?assertEqual(
        #{
            <<"text">> => <<"hi there">>,
            <<"phones">> => <<"+15551234567">>,
            <<"from">> => <<"447700">>
        },
        ?F:body_form_single(Req)
    ).

messageid_fallback_and_passthrough_test() ->
    {C, P} = cfg(#{}, [?F:resp(201, <<"{\"messageId\":99}">>)]),
    {ok, R} = ?N:send_sms(C, (sms())#{
        passthrough => #{body => #{templateId => 7, <<"cutExtra">> => <<"1">>}}
    }),
    ?assertEqual(<<"99">>, maps:get(provider_message_id, R)),
    Form = ?F:body_form_single(?F:last(P)),
    ?assertEqual(<<"7">>, maps:get(<<"templateId">>, Form)),
    ?assertEqual(<<"1">>, maps:get(<<"cutExtra">>, Form)),
    %% No sender configured or provided -> no `from` field in the form.
    ?assertNot(maps:is_key(<<"from">>, Form)).

error_invalid_recipient_422_test() ->
    {C, _} = cfg(#{}, [?F:resp(422, <<"{\"message\":\"Invalid phone number\",\"code\":10}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_recipient, status := 422, provider_message := <<"Invalid phone number">>
        }},
        ?N:send_sms(C, (sms())#{to => <<"not-a-number">>})
    ).

error_auth_test() ->
    {C, _} = cfg(#{api_key => <<"bad">>}, [?F:resp(401, <<"{\"message\":\"Unauthorized\"}">>)]),
    ?assertMatch({error, #{code := auth_failed}}, ?N:send_sms(C, sms())).

error_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, Body)]),
            ?assertMatch({error, #{code := Want, provider_message := Msg}}, ?N:send_sms(C, sms()))
        end)
     || {S, Body, Want, Msg} <- [
            {403, <<"{\"code\":403}">>, auth_failed, <<"Textmagic HTTP 403 403">>},
            {429, <<>>, rate_limited, <<"Textmagic HTTP 429">>},
            {500, <<"{\"code\":\"\"}">>, provider_unavailable, <<"Textmagic HTTP 500">>},
            {400, <<"{\"code\":\"E1\"}">>, invalid_request, <<"Textmagic HTTP 400 E1">>},
            {302, <<>>, unknown, <<"Textmagic HTTP 302">>}
        ]
    ].

%% test_request_guards.py: the SMS was accepted (201); a crash here would
%% invite a duplicate retry. OTP's decoder rejects NaN/1e999 outright, so
%% those bodies decode to null and the id is empty.
accepted_send_never_raises_on_odd_ids_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{from => <<"A">>}, [?F:resp(201, Body)]),
            ?assertMatch(
                {ok, #{success := true, provider_message_id := Want}}, ?N:send_sms(C, sms())
            )
        end)
     || {Body, Want} <- [
            {<<"{\"id\":1e999}">>, <<>>},
            {<<"{\"id\":NaN}">>, <<>>},
            {<<"{\"id\":12345}">>, <<"12345">>},
            {<<"{\"id\":12.0}">>, <<"12">>},
            {<<"{\"id\":{\"a\":1}}">>, <<"{\"a\":1}">>},
            {<<"{\"id\":null,\"messageId\":\"m-1\"}">>, <<"m-1">>},
            {<<"{\"messageId\":\"m-1\"}">>, <<"m-1">>}
        ]
    ].

non_finite_error_code_still_a_connector_error_test() ->
    {C, _} = cfg(#{from => <<"A">>}, [?F:resp(400, <<"{\"code\":Infinity}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())).
