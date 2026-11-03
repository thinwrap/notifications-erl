-module(thinwrap_notifications_whatsappbusiness_tests).

%% Ported from the Python sibling's tests/test_whatsappbusiness.py, plus the
%% WhatsApp cases of test_core.py (path escaping), test_passthrough_casing.py
%% and test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => 'whatsapp-business',
                access_token => <<"tok">>,
                phone_number_id => <<"1">>
            },
            Extra
        ),
        Responses
    ).

ok_resp() -> ?F:resp(200, <<"{\"messages\":[{\"id\":\"m1\"}]}">>).

send_test() ->
    {C, P} = cfg(#{phone_number_id => <<"123456">>}, [
        ?F:resp(200, <<"{\"messages\":[{\"id\":\"wamid.ABC123\"}]}">>)
    ]),
    {ok, R} = ?N:send_chat(C, #{to => <<"+15551234567">>, body => <<"hi there">>}),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"wamid.ABC123">>}, R),
    Req = ?F:last(P),
    ?assertEqual(<<"graph.facebook.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v21.0/123456/messages">>, ?F:path_of(Req)),
    ?assertEqual(<<"Bearer tok">>, ?F:header(Req, <<"Authorization">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    ?assertEqual(
        #{
            <<"messaging_product">> => <<"whatsapp">>,
            <<"recipient_type">> => <<"individual">>,
            <<"to">> => <<"+15551234567">>,
            <<"type">> => <<"text">>,
            <<"text">> => #{<<"body">> => <<"hi there">>}
        },
        ?F:body_json(Req)
    ).

version_override_test() ->
    {C, P} = cfg(#{phone_number_id => <<"999">>, graph_api_version => <<"v20.0">>}, [ok_resp()]),
    {ok, _} = ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>}),
    ?assertEqual(<<"/v20.0/999/messages">>, ?F:path_of(?F:last(P))).

empty_version_falls_back_to_default_test() ->
    {C, P} = cfg(#{graph_api_version => <<>>}, [ok_resp()]),
    {ok, _} = ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>}),
    ?assertEqual(<<"/v21.0/1/messages">>, ?F:path_of(?F:last(P))).

%% Python's test calls this "snake_case passthrough", but the connector does
%% no casing: a camelCase top-level key rides verbatim next to the
%% connector's own recipient_type; nested maps deep-merge into the
%% connector-built "text".
passthrough_keys_verbatim_and_deep_merged_test() ->
    {C, P} = cfg(#{}, [ok_resp()]),
    {ok, _} = ?N:send_chat(C, #{
        to => <<"+1">>,
        body => <<"hi">>,
        passthrough => #{
            body => #{
                <<"recipientType">> => <<"individual">>,
                <<"text">> => #{<<"preview_url">> => true},
                <<"context">> => #{<<"message_id">> => <<"wamid.PREV">>}
            },
            query => #{appsecret_proof => <<"p">>}
        }
    }),
    Req = ?F:last(P),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"individual">>, maps:get(<<"recipient_type">>, Payload)),
    ?assertEqual(<<"individual">>, maps:get(<<"recipientType">>, Payload)),
    ?assertEqual(
        #{<<"body">> => <<"hi">>, <<"preview_url">> => true}, maps:get(<<"text">>, Payload)
    ),
    ?assertEqual(#{<<"message_id">> => <<"wamid.PREV">>}, maps:get(<<"context">>, Payload)),
    %% The passthrough query is forwarded.
    ?assertEqual(<<"p">>, ?F:qget(Req, <<"appsecret_proof">>)).

template_parameters_verbatim_test() ->
    {C, P} = cfg(#{}, [ok_resp()]),
    Template = #{
        <<"name">> => <<"order_update">>,
        <<"language">> => #{<<"code">> => <<"en_US">>},
        <<"components">> => [
            #{
                <<"type">> => <<"body">>,
                <<"parameters">> => [
                    #{
                        <<"type">> => <<"text">>,
                        <<"parameter_name">> => <<"firstName">>,
                        <<"text">> => <<"Ada">>
                    }
                ]
            }
        ]
    },
    {ok, _} = ?N:send_chat(C, #{
        to => <<"+1">>,
        body => <<"hi">>,
        passthrough => #{body => #{<<"type">> => <<"template">>, <<"template">> => Template}}
    }),
    ?assertEqual(Template, maps:get(<<"template">>, ?F:body_json(?F:last(P)))).

requires_to_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_request,
            message := <<"WhatsApp Business requires `to` (E.164 phone number).">>
        }},
        ?N:send_chat(C, #{body => <<"no recipient">>})
    ),
    ?assertEqual([], ?F:calls(P)).

error_auth_test() ->
    {C, _} = cfg(#{access_token => <<"bad">>}, [
        ?F:resp(401, <<"{\"error\":{\"code\":190,\"message\":\"invalid token\"}}">>)
    ]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 401, provider_message := <<"invalid token">>}},
        ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>})
    ).

%% Cloud API error codes
%% (developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes).
%% Most arrive as HTTP 400, so the code, not the status, decides.
error_code_table_test_() ->
    [
        ?_test(begin
            Body =
                <<"{\"error\":{\"code\":", (integer_to_binary(Code))/binary,
                    ",\"message\":\"m\"}}">>,
            {C, _} = cfg(#{}, [?F:resp(400, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := 400}},
                ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>})
            )
        end)
     || {Code, Want} <- [
            %% "More than 24 hours have passed since recipient last replied"
            {131047, invalid_request},
            %% "The request is missing a required parameter."
            {131008, invalid_request},
            %% business "Phone number not registered"
            {133010, invalid_request},
            %% "Too many messages sent ... to the same recipient"
            {131056, rate_limited},
            %% "Rate limit hit"
            {130429, rate_limited},
            %% spam rate limit
            {131048, rate_limited},
            {4, rate_limited},
            {80007, rate_limited},
            %% "We were unable to authenticate the app user"
            {0, auth_failed},
            %% "Permission is either not granted or has been removed"
            {10, auth_failed},
            %% 200-299 permission family
            {200, auth_failed},
            {250, auth_failed},
            {299, auth_failed},
            {3, auth_failed},
            {190, auth_failed},
            {368, auth_failed},
            {131005, auth_failed},
            {131031, auth_failed},
            %% message undeliverable
            {131026, invalid_recipient},
            %% sender and recipient are the same
            {131021, invalid_recipient},
            %% "A service is temporarily unavailable."
            {131016, provider_unavailable},
            {1, provider_unavailable},
            {2, provider_unavailable},
            {131000, provider_unavailable},
            {131057, provider_unavailable},
            {100, invalid_request},
            {131009, invalid_request},
            {131042, invalid_request},
            {131045, invalid_request},
            {131051, invalid_request},
            {132000, invalid_request},
            {132001, invalid_request},
            {132012, invalid_request},
            %% An unknown code falls back to the status.
            {300, invalid_request},
            {199, invalid_request}
        ]
    ].

%% Code 0 is an auth failure; a body without a code must fall back to the
%% status.
missing_code_is_not_code_zero_test() ->
    {C, _} = cfg(#{}, [?F:resp(400, <<"{\"error\":{\"message\":\"bad\"}}">>)]),
    ?assertMatch(
        {error, #{code := invalid_request}}, ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>})
    ).

code_shapes_test_() ->
    [
        ?_test(begin
            Body = <<"{\"error\":{\"code\":", Code/binary, "}}">>,
            {C, _} = cfg(#{}, [?F:resp(S, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := S, message := Msg}},
                ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>})
            )
        end)
     || {S, Code, Want, Msg} <- [
            %% A float code truncates (Python int()).
            {400, <<"131056.0">>, rate_limited, <<"WhatsApp HTTP 400">>},
            {400, <<"1.5">>, provider_unavailable, <<"WhatsApp HTTP 400">>},
            %% Not a number, or a number no float can hold: the status decides.
            {429, <<"\"190\"">>, rate_limited, <<"WhatsApp HTTP 429">>},
            {400, <<"true">>, invalid_request, <<"WhatsApp HTTP 400">>},
            {400, <<"9007199254740993">>, invalid_request, <<"WhatsApp HTTP 400">>},
            {403, <<"null">>, auth_failed, <<"WhatsApp HTTP 403">>},
            {503, <<"7">>, provider_unavailable, <<"WhatsApp HTTP 503">>},
            {409, <<"7">>, unknown, <<"WhatsApp HTTP 409">>}
        ]
    ].

retry_after_surfaces_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(429, <<"{\"error\":{\"code\":4,\"message\":\"m\"}}">>, #{
            <<"Retry-After">> => <<"60">>
        })
    ]),
    {error, #{cause := Cause}} = ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>}),
    ?assertEqual(60, maps:get(<<"retryAfterSeconds">>, Cause)).

non_json_success_has_empty_id_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<"{\"messages\":[]}">>)]),
    ?assertMatch(
        {ok, #{provider_message_id := <<>>}}, ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>})
    ).

%% --- test_core.py: config values in URL paths are escaped -------------------

config_path_segments_escaped_test() ->
    {C, P} = cfg(#{phone_number_id => <<"1/x">>, graph_api_version => <<"v21.0/y">>}, [
        ?F:resp(200, <<"{\"messages\":[{\"id\":\"w\"}]}">>)
    ]),
    {ok, _} = ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>}),
    ?assertEqual(<<"/v21.0%2Fy/1%2Fx/messages">>, ?F:path_of(?F:last(P))).

%% --- test_passthrough_casing.py ---------------------------------------------

keys_as_given_test() ->
    {C, P} = cfg(#{access_token => <<"T">>, phone_number_id => <<"123">>}, [
        ?F:resp(200, <<"{\"messages\":[{\"id\":\"wamid.1\"}]}">>)
    ]),
    {ok, _} = ?N:send_chat(C, #{
        to => <<"+15551234567">>,
        body => <<"b">>,
        passthrough => #{
            body => #{<<"biz_opaque_callback_data">> => <<"ref-1">>, <<"camelKey">> => true}
        }
    }),
    Payload = ?F:body_json(?F:last(P)),
    ?assertEqual(<<"ref-1">>, maps:get(<<"biz_opaque_callback_data">>, Payload)),
    ?assertEqual(true, maps:get(<<"camelKey">>, Payload)),
    ?assertNot(maps:is_key(<<"camel_key">>, Payload)).

%% --- test_request_guards.py -------------------------------------------------

%% OTP's decoder rejects NaN, so the body is unreadable and the status decides
%% — the same outcome as the Python sibling's non-finite guard.
nan_code_falls_back_to_status_test() ->
    {C, _} = cfg(#{access_token => <<"T">>}, [
        ?F:resp(400, <<"{\"error\":{\"code\":NaN,\"message\":\"x\"}}">>)
    ]),
    ?assertMatch(
        {error, #{code := invalid_request}}, ?N:send_chat(C, #{to => <<"+1">>, body => <<"x">>})
    ).
