-module(thinwrap_notifications_request_guards_tests).

%% Request-shaping guards shared by every connector: headers, URLs, body
%% encoding, vendor numbers. Ported from the email cases of the Python
%% sibling's tests/test_request_guards.py (SMS/push/chat cases land with their
%% connectors; the default-transport cases live in the httpc tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

sendgrid(Extra) ->
    ?F:config(
        maps:merge(#{provider => sendgrid, api_key => <<"SG.k">>, from => <<"f@acme.com">>}, Extra),
        [?F:resp(202, <<>>, #{<<"x-message-id">> => <<"sg-1">>})]
    ).

assert_invalid_request(Result, P, Secret) ->
    ?assertMatch({error, #{code := invalid_request}}, Result),
    ?assertEqual([], ?F:calls(P)),
    case Secret of
        undefined ->
            ok;
        _ ->
            {error, E} = Result,
            Text = iolist_to_binary(io_lib:format("~p", [E])),
            ?assertEqual(nomatch, binary:match(Text, Secret))
    end.

%% --- header / URL guard ---------------------------------------------------

api_key_with_trailing_newline_is_invalid_request_not_retryable_test() ->
    %% An HTTP client refuses the header before connecting; that is a config
    %% error, not a provider outage.
    {C, P} = sendgrid(#{api_key => <<"SG.secret-value\n">>}),
    R = ?N:send_email(C, email()),
    assert_invalid_request(R, P, <<"SG.secret-value">>),
    {error, #{message := Msg}} = R,
    ?assertNotEqual(nomatch, binary:match(Msg, <<"Authorization">>)).

control_characters_in_passthrough_header_value_rejected_test_() ->
    [
        ?_test(begin
            {C, P} = sendgrid(#{}),
            R = ?N:send_email(C, (email())#{passthrough => #{headers => #{<<"X-Ref">> => V}}}),
            assert_invalid_request(R, P, V)
        end)
     || V <- [<<"a\r\nX-Injected: 1">>, <<"a\nb">>, <<"a\rb">>, <<"a", 0, "b">>, <<"a", 1, "b">>]
    ].

bad_header_name_rejected_test_() ->
    [
        ?_test(begin
            {C, P} = sendgrid(#{}),
            R = ?N:send_email(C, (email())#{passthrough => #{headers => #{Name => <<"v">>}}}),
            assert_invalid_request(R, P, undefined)
        end)
     || Name <- [
            <<"X Bad">>,
            <<"X:Bad">>,
            <<"X\r\nBad">>,
            <<>>,
            <<"X-é"/utf8>>,
            <<"X(y)">>,
            <<"X\"y">>,
            <<"X/y">>,
            <<"X@y">>
        ]
    ].

scalar_header_values_are_stringified_and_lists_rejected_test() ->
    {C, P} = sendgrid(#{}),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{headers => #{<<"X-Num">> => 3, 'X-Flag' => true, <<"X-F">> => 1.5}}
    }),
    Req = ?F:last(P),
    ?assertEqual(<<"3">>, ?F:header(Req, <<"X-Num">>)),
    ?assertEqual(<<"true">>, ?F:header(Req, <<"X-Flag">>)),
    ?assertEqual(<<"1.5">>, ?F:header(Req, <<"X-F">>)),
    {C2, P2} = sendgrid(#{}),
    R = ?N:send_email(C2, (email())#{passthrough => #{headers => #{<<"X-List">> => [<<"a">>]}}}),
    assert_invalid_request(R, P2, undefined).

tab_in_header_value_is_allowed_test() ->
    {C, P} = sendgrid(#{}),
    {ok, _} = ?N:send_email(C, (email())#{passthrough => #{headers => #{<<"X-Ref">> => <<"a\tb">>}}}),
    ?assertEqual(<<"a\tb">>, ?F:header(?F:last(P), <<"X-Ref">>)).

header_value_beyond_latin1_rejected_test() ->
    {C, P} = sendgrid(#{}),
    R = ?N:send_email(C, (email())#{passthrough => #{headers => #{<<"X-Ref">> => <<"€"/utf8>>}}}),
    assert_invalid_request(R, P, undefined),
    {C2, P2} = sendgrid(#{}),
    {ok, _} = ?N:send_email(C2, (email())#{
        passthrough => #{headers => #{<<"X-Ref">> => <<"café"/utf8>>}}
    }),
    ?assertEqual(<<"café"/utf8>>, ?F:header(?F:last(P2), <<"X-Ref">>)).

mailgun(BaseUrl) ->
    ?F:config(
        #{
            provider => mailgun,
            api_key => <<"k">>,
            domain => <<"mg.example.com">>,
            from => <<"f@e.com">>,
            base_url => BaseUrl
        },
        [?F:resp(200, <<"{\"id\":\"x\"}">>)]
    ).

url_with_whitespace_is_invalid_request_test() ->
    {C, P} = mailgun(<<"https://api.mailgun.net/T0 0">>),
    assert_invalid_request(?N:send_email(C, email()), P, <<"T0 0">>).

bad_port_or_non_ascii_url_rejected_test_() ->
    [
        ?_test(begin
            {C, P} = mailgun(Url),
            assert_invalid_request(?N:send_email(C, email()), P, <<"secretpath">>)
        end)
     || Url <- [
            <<"https://api.mailgun.net:abc/secretpath">>,
            <<"https://api.mailgun.net:99999/secretpath">>,
            <<"https://api.mailgun.net/secretpathé"/utf8>>
        ]
    ].

good_ports_pass_test_() ->
    [
        ?_test(begin
            {C, P} = mailgun(Url),
            {ok, _} = ?N:send_email(C, email()),
            ?assertEqual(1, length(?F:calls(P)))
        end)
     || Url <- [
            <<"https://api.mailgun.net:443">>,
            <<"https://user:pw@api.mailgun.net:8443">>,
            <<"https://[::1]:8443">>,
            <<"https://[::1]">>,
            <<"https://api.mailgun.net:">>
        ]
    ].

%% --- encoding failures ------------------------------------------------------

assert_encode_error(Result, P) ->
    ?assertMatch(
        {error, #{code := invalid_request, cause := #{<<"raw">> := #{<<"exception">> := _}}}},
        Result
    ),
    ?assertEqual([], ?F:calls(P)).

mailgun_non_json_value_is_invalid_request_on_form_and_multipart_test_() ->
    [
        ?_test(begin
            {C, P} = ?F:config(
                #{
                    provider => mailgun,
                    api_key => <<"k">>,
                    domain => <<"mg.example.com">>,
                    from => <<"f@e.com">>
                },
                [?F:resp(200, <<"{\"id\":\"x\"}">>)]
            ),
            R = ?N:send_email(C, (email())#{
                attachments => Atts,
                passthrough => #{body => #{<<"t:variables">> => #{<<"when">> => {2026, 1, 1}}}}
            }),
            assert_encode_error(R, P)
        end)
     || Atts <- [[], [#{filename => <<"f.txt">>, content => <<"x">>}]]
    ].

%% The Erlang analogue of the siblings' lone-surrogate case: a binary that is
%% not valid UTF-8 can never be encoded for the vendor.
invalid_utf8_is_invalid_request_everywhere_test_() ->
    Bad = <<"hi", 16#ff>>,
    Cfgs = [
        #{
            provider => mailgun,
            api_key => <<"k">>,
            domain => <<"mg.example.com">>,
            from => <<"f@e.com">>
        },
        #{
            provider => ses,
            region => <<"us-east-1">>,
            access_key_id => <<"AKID">>,
            secret_access_key => <<"s">>,
            from => <<"a@b.com">>
        },
        #{provider => sendgrid, api_key => <<"k">>, from => <<"a@b.com">>}
    ],
    [
        ?_test(begin
            {C, P} = ?F:config(Cfg, [?F:resp(200, <<"{}">>)]),
            assert_encode_error(?N:send_email(C, (email())#{text => Bad}), P)
        end)
     || Cfg <- Cfgs
    ] ++
        [
            ?_test(begin
                {C, P} = ?F:config(hd(Cfgs), [?F:resp(200, <<"{}">>)]),
                R = ?N:send_email(C, (email())#{
                    text => Bad, attachments => [#{filename => <<"f">>, content => <<"x">>}]
                }),
                assert_encode_error(R, P)
            end)
        ].

unencodable_passthrough_value_is_invalid_request_test() ->
    {C, P} = sendgrid(#{}),
    assert_encode_error(?N:send_email(C, (email())#{passthrough => #{body => #{x => self()}}}), P).

%% --- vendor numbers ---------------------------------------------------------

postmark_huge_error_code_does_not_raise_raw_test() ->
    %% OTP's decoder rejects 1e999 outright, so the body decodes to null and the
    %% status decides.
    {C, _} = ?F:config(
        #{provider => postmark, server_token => <<"t">>, from => <<"f@a.com">>},
        [?F:resp(422, <<"{\"ErrorCode\":1e999,\"Message\":\"x\"}">>)]
    ),
    ?assertMatch(
        {error, #{code := invalid_request, cause := #{<<"raw">> := null}}},
        ?N:send_email(C, email())
    ).

%% --- pre-formatted sender ---------------------------------------------------

preformatted_from_is_parsed_not_nested_test_() ->
    Cases = [
        {<<>>, <<"Zoë <z@x.com>"/utf8>>, <<"=?UTF-8?B?Wm/Dqw==?= <z@x.com>">>},
        {<<"Bob">>, <<"Zoë <z@x.com>"/utf8>>, <<"=?UTF-8?B?Wm/Dqw==?= <z@x.com>">>},
        {<<"Bob">>, <<"\"Doe, Jane\" <j@x.com>">>, <<"\"Doe, Jane\" <j@x.com>">>},
        {<<"Bob">>, <<"<j@x.com>">>, <<"Bob <j@x.com>">>}
    ],
    [
        ?_test(begin
            {C, P} = ?F:config(
                #{
                    provider => resend,
                    api_key => <<"k">>,
                    from => <<"ignored@x.com">>,
                    sender_name => Name
                },
                [?F:resp(200, <<"{\"id\":\"m\"}">>)]
            ),
            {ok, _} = ?N:send_email(C, (email())#{from => From}),
            ?assertEqual(Want, maps:get(<<"from">>, ?F:body_json(?F:last(P))))
        end)
     || {Name, From, Want} <- Cases
    ].
