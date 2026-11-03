-module(thinwrap_notifications_telnyx_tests).

%% Ported from the Python sibling's tests/test_telnyx.py, plus the Telnyx case
%% of test_passthrough_casing.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(200, <<"{\"data\":{\"id\":\"m\"}}">>)).

cfg(Extra, Responses) ->
    ?F:config(maps:merge(#{provider => telnyx, api_key => <<"K">>}, Extra), Responses).

sms() -> #{to => <<"+1">>, body => <<"b">>}.

send_json_bearer_and_passthrough_test() ->
    {C, P} = cfg(#{api_key => <<"KEY">>, from => <<"+15550000000">>}, [
        ?F:resp(200, <<"{\"data\":{\"id\":\"msg-1\",\"record_type\":\"message\"}}">>)
    ]),
    {ok, R} = ?N:send_sms(C, #{
        to => <<"+15551111111">>,
        body => <<"ping">>,
        passthrough => #{
            body => #{
                <<"messaging_profile_id">> => <<"mp-1">>, <<"webhook_url">> => <<"https://x/y">>
            }
        }
    }),
    %% unwrapped from data.id; raw keeps the envelope
    ?assertMatch(
        #{
            success := true,
            status := sent,
            provider_message_id := <<"msg-1">>,
            raw := #{<<"data">> := #{<<"record_type">> := <<"message">>}}
        },
        R
    ),
    Req = ?F:last(P),
    ?assertEqual(<<"api.telnyx.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v2/messages">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer KEY">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(
        #{
            <<"to">> => <<"+15551111111">>,
            <<"text">> => <<"ping">>,
            <<"from">> => <<"+15550000000">>,
            %% passthrough keys ride as given (Telnyx wire names).
            <<"messaging_profile_id">> => <<"mp-1">>,
            <<"webhook_url">> => <<"https://x/y">>
        },
        ?F:body_json(Req)
    ).

messaging_profile_passthrough_no_sender_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_sms(C, (sms())#{passthrough => #{body => #{messaging_profile_id => <<"mp">>}}}),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"mp">>, maps:get(<<"messaging_profile_id">>, Payload)),
    ?assertNot(maps:is_key(<<"from">>, Payload)).

requires_sender_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{}">>)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
    ?assertEqual([], ?F:calls(P)).

error_invalid_recipient_422_test() ->
    %% Telnyx errors[].code is a numeric string; 40310 = "Invalid 'to' address".
    {C, _} = cfg(#{from => <<"+1">>}, [
        ?F:resp(
            422,
            <<
                "{\"errors\":[{\"code\":\"40310\",\"title\":\"Invalid 'to' address\","
                "\"detail\":\"invalid to number\"}]}"
            >>
        )
    ]),
    ?assertMatch(
        {error, #{code := invalid_recipient, provider_message := <<"invalid to number">>}},
        ?N:send_sms(C, sms())
    ).

error_auth_failed_test() ->
    {C, _} = cfg(#{api_key => <<"bad">>, from => <<"+1">>}, [
        ?F:resp(401, <<"{\"errors\":[{\"title\":\"Unauthorized\"}]}">>)
    ]),
    ?assertMatch(
        {error, #{code := auth_failed, provider_message := <<"Unauthorized">>}},
        ?N:send_sms(C, sms())
    ).

error_code_table_test_() ->
    [
        ?_test(begin
            Body = <<"{\"errors\":[{\"code\":\"", Code/binary, "\",\"title\":\"t\"}]}">>,
            {C, _} = cfg(#{from => <<"+1">>}, [?F:resp(S, Body)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_sms(C, sms()))
        end)
     || {S, Code, Want} <- [
            %% "Authentication failed"
            {401, <<"10009">>, auth_failed},
            %% "Invalid messaging profile secret"
            {422, <<"40311">>, auth_failed},
            %% "Too many requests"
            {429, <<"10011">>, rate_limited},
            %% "Message queue full"
            {422, <<"40318">>, rate_limited},
            %% "Invalid 'from' address"
            {422, <<"40305">>, invalid_request},
            %% "Blocked due to STOP message"
            {422, <<"40300">>, invalid_recipient},
            %% a bare 422 is not a recipient signal
            {422, <<>>, invalid_request},
            %% "Bad Request"
            {400, <<"10015">>, invalid_request},
            %% the code decides before the status
            {500, <<"40309">>, invalid_recipient},
            {403, <<"20100">>, invalid_request},
            %% unlisted codes fall back to the status
            {403, <<"99999">>, auth_failed},
            {429, <<"99999">>, rate_limited},
            {503, <<"99999">>, provider_unavailable},
            {302, <<"99999">>, unknown}
        ]
    ].

code_10002_on_to_pointer_is_invalid_recipient_test_() ->
    %% API errors carry source.pointer; 10002 "Invalid phone number" on /to is
    %% the recipient, on any other field the request.
    [
        ?_test(begin
            Body =
                <<
                    "{\"errors\":[{\"code\":\"10002\",\"title\":\"Invalid phone number\","
                    "\"source\":{\"pointer\":\"",
                    Pointer/binary,
                    "\"}}]}"
                >>,
            {C, _} = cfg(#{from => <<"+1">>}, [?F:resp(422, Body)]),
            ?assertMatch(
                {error, #{code := Want, provider_message := <<"Invalid phone number">>}},
                ?N:send_sms(C, sms())
            )
        end)
     || {Pointer, Want} <- [{<<"/to">>, invalid_recipient}, {<<"/from">>, invalid_request}]
    ].

error_without_body_test() ->
    {C, _} = cfg(#{from => <<"+1">>}, [?F:resp(500, <<>>)]),
    ?assertMatch(
        {error, #{code := provider_unavailable, provider_message := <<"Telnyx HTTP 500">>}},
        ?N:send_sms(C, sms())
    ).

keys_as_given_test() ->
    {C, P} = cfg(#{from => <<"+15550000000">>}, [?OK]),
    {ok, _} = ?N:send_sms(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{
            body => #{
                <<"messaging_profile_id">> => <<"mp-1">>, <<"webhook_url">> => <<"https://cb">>
            }
        }
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"mp-1">>, maps:get(<<"messaging_profile_id">>, Payload)),
    ?assertEqual(<<"https://cb">>, maps:get(<<"webhook_url">>, Payload)).
