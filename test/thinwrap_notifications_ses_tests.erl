-module(thinwrap_notifications_ses_tests).

%% Ported from the Python sibling's tests/test_ses.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(AUTH_RE,
    "^AWS4-HMAC-SHA256 Credential=TESTKEYID/\\d{8}/us-east-1/ses/aws4_request, "
    "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=[0-9a-f]{64}$"
).
-define(OK, ?F:resp(200, <<"{\"MessageId\":\"m1\"}">>)).

base() ->
    #{
        provider => ses,
        region => <<"us-east-1">>,
        access_key_id => <<"TESTKEYID">>,
        secret_access_key => <<"test-secret">>,
        from => <<"sender@example.com">>,
        sender_name => <<"Test Sender">>
    }.

cfg(Extra, Responses) -> ?F:config(maps:merge(base(), Extra), Responses).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

matches(B, Re) -> re:run(B, Re, [{capture, none}]) =:= match.

send_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{\"MessageId\":\"abc-123\"}">>)]),
    {ok, R} = ?N:send_email(C, #{
        from => <<"sender@example.com">>,
        to => <<"recipient@example.com">>,
        subject => <<"Hello">>,
        html => <<"<p>Hi!</p>">>,
        text => <<"Hi!">>
    }),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"abc-123">>}, R),
    Req = ?F:last(P),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"email.us-east-1.amazonaws.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v2/email/outbound-emails">>, ?F:path_of(Req)),
    ?assert(matches(?F:header(Req, <<"Authorization">>), ?AUTH_RE)),
    ?assert(matches(?F:header(Req, <<"X-Amz-Date">>), "^\\d{8}T\\d{6}Z$")),
    ?assert(matches(?F:header(Req, <<"X-Amz-Content-Sha256">>), "^[0-9a-f]{64}$")),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    %% The signed payload hash is the hash of the bytes actually sent.
    ?assertEqual(
        binary:encode_hex(crypto:hash(sha256, maps:get(body, Req)), lowercase),
        ?F:header(Req, <<"X-Amz-Content-Sha256">>)
    ),
    Body = ?F:body_json(Req),
    ?assertEqual(<<"Test Sender <sender@example.com>">>, maps:get(<<"FromEmailAddress">>, Body)),
    ?assertEqual(
        [<<"recipient@example.com">>],
        maps:get(<<"ToAddresses">>, maps:get(<<"Destination">>, Body))
    ),
    Simple = maps:get(<<"Simple">>, maps:get(<<"Content">>, Body)),
    ?assertEqual(<<"Hello">>, maps:get(<<"Data">>, maps:get(<<"Subject">>, Simple))),
    ?assertEqual(
        #{
            <<"Html">> => #{<<"Data">> => <<"<p>Hi!</p>">>, <<"Charset">> => <<"UTF-8">>},
            <<"Text">> => #{<<"Data">> => <<"Hi!">>, <<"Charset">> => <<"UTF-8">>}
        },
        maps:get(<<"Body">>, Simple)
    ).

attachments_use_simple_content_test() ->
    %% SES v2 Message.Attachments: RawContent is a blob (base64 over HTTPS),
    %% FileName required, ContentDisposition ATTACHMENT|INLINE.
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, #{
        to => <<"recipient@example.com">>,
        subject => <<"Sübject"/utf8>>,
        html => <<"<p>hi <img src=\"cid:logo\"></p>">>,
        bcc => [<<"b@example.com">>],
        cc => [<<"c@example.com">>],
        reply_to => <<"r@example.com">>,
        attachments => [
            #{
                filename => <<"file.txt">>,
                content_type => <<"text/plain">>,
                content => <<"hello world">>
            },
            #{
                filename => <<"logo.png">>,
                content_type => <<"image/png">>,
                content => <<16#89, "PNG">>,
                content_id => <<"logo">>
            },
            #{filename => <<"blob.bin">>, content => <<"x">>}
        ]
    }),
    Body = ?F:body_json(?F:last(P)),
    ?assertNot(maps:is_key(<<"Raw">>, maps:get(<<"Content">>, Body))),
    Simple = maps:get(<<"Simple">>, maps:get(<<"Content">>, Body)),
    ?assertEqual(
        #{<<"Data">> => <<"Sübject"/utf8>>, <<"Charset">> => <<"UTF-8">>},
        maps:get(<<"Subject">>, Simple)
    ),
    ?assertEqual(
        [
            #{
                <<"FileName">> => <<"file.txt">>,
                <<"RawContent">> => base64:encode(<<"hello world">>),
                <<"ContentType">> => <<"text/plain">>,
                <<"ContentDisposition">> => <<"ATTACHMENT">>
            },
            #{
                <<"FileName">> => <<"logo.png">>,
                <<"RawContent">> => base64:encode(<<16#89, "PNG">>),
                <<"ContentType">> => <<"image/png">>,
                <<"ContentId">> => <<"logo">>,
                <<"ContentDisposition">> => <<"INLINE">>
            },
            #{
                <<"FileName">> => <<"blob.bin">>,
                <<"RawContent">> => <<"eA==">>,
                <<"ContentDisposition">> => <<"ATTACHMENT">>
            }
        ],
        maps:get(<<"Attachments">>, Simple)
    ),
    %% Bcc stays envelope-only (Destination), never a header.
    ?assertNot(maps:is_key(<<"Headers">>, Simple)),
    ?assertEqual(
        #{
            <<"ToAddresses">> => [<<"recipient@example.com">>],
            <<"CcAddresses">> => [<<"c@example.com">>],
            <<"BccAddresses">> => [<<"b@example.com">>]
        },
        maps:get(<<"Destination">>, Body)
    ),
    ?assertEqual([<<"r@example.com">>], maps:get(<<"ReplyToAddresses">>, Body)).

non_ascii_sender_name_is_encoded_word_test() ->
    %% SES: a Unicode "friendly from" name must use MIME encoded-word syntax.
    {C, P} = cfg(#{sender_name => <<"Bjørn Ålesund"/utf8>>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    From = maps:get(<<"FromEmailAddress">>, ?F:body_json(?F:last(P))),
    ?assertMatch(<<"=?UTF-8?B?", _/binary>>, From),
    [Phrase, <<"sender@example.com>">>] = binary:split(From, <<" <">>),
    ?assertEqual(<<"Bjørn Ålesund"/utf8>>, decode_words(Phrase)).

long_non_ascii_name_splits_into_75_char_words_test() ->
    %% RFC 2047 §2: "An 'encoded-word' may not be more than 75 characters long".
    Name = binary:copy(<<"Ünïcødé Sender "/utf8>>, 8),
    {C, P} = cfg(#{sender_name => Name}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    From = maps:get(<<"FromEmailAddress">>, ?F:body_json(?F:last(P))),
    [Phrase | _] = binary:split(From, <<" <">>),
    Words = binary:split(Phrase, <<" ">>, [global]),
    ?assertMatch([_, _ | _], Words),
    ?assert(lists:all(fun(W) -> byte_size(W) =< 75 end, Words)),
    ?assertEqual(string:trim(Name), decode_words(Phrase)).

decode_words(Phrase) ->
    iolist_to_binary([
        base64:decode(binary:part(W, 10, byte_size(W) - 12))
     || W <- binary:split(Phrase, <<" ">>, [global])
    ]).

ascii_sender_name_with_specials_is_quoted_test() ->
    %% RFC 5322 §3.2.3: a display name with specials must be a quoted-string.
    {C, P} = cfg(#{sender_name => <<"Doe, Jane \"JD\" Jr.">>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(
        <<"\"Doe, Jane \\\"JD\\\" Jr.\" <sender@example.com>">>,
        maps:get(<<"FromEmailAddress">>, ?F:body_json(?F:last(P)))
    ).

custom_headers_simple_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        headers => #{<<"X-Campaign">> => <<"fall">>, <<"X-Name">> => <<"Renée"/utf8>>}
    }),
    [H1, H2] = maps:get(
        <<"Headers">>, maps:get(<<"Simple">>, maps:get(<<"Content">>, ?F:body_json(?F:last(P))))
    ),
    ?assertEqual(#{<<"Name">> => <<"X-Campaign">>, <<"Value">> => <<"fall">>}, H1),
    %% MessageHeader.Value pattern "[ -~]*": non-ASCII goes out as an encoded-word.
    ?assertMatch(#{<<"Name">> := <<"X-Name">>, <<"Value">> := <<"=?UTF-8?B?", _/binary>>}, H2).

disallowed_custom_header_rejected_before_sending_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{}, [?OK]),
            {error, E} = ?N:send_email(C, (email())#{headers => #{Name => <<"x@example.com">>}}),
            ?assertMatch(#{code := invalid_request}, E),
            ?assertEqual([], ?F:calls(P))
        end)
     || Name <- [
            <<"Reply-To">>,
            <<"to">>,
            <<"CC">>,
            <<"From">>,
            <<"Subject">>,
            <<"Content-Type">>,
            <<"Message-ID">>
        ]
    ].

disallowed_header_hint_names_the_input_key_test() ->
    {C, _} = cfg(#{}, [?OK]),
    ?assertMatch(
        {error, #{
            message := <<"SES does not allow a custom Reply-To header; set `reply_to` instead.">>
        }},
        ?N:send_email(C, (email())#{headers => #{<<"Reply-To">> => <<"x">>}})
    ),
    ?assertMatch(
        {error, #{message := <<"SES does not allow a custom Date header.">>}},
        ?N:send_email(C, (email())#{headers => #{<<"Date">> => <<"x">>}})
    ).

header_limits_rejected_before_sending_test() ->
    %% MessageHeaderList max 15; name+value max 996; value max 995 printable ASCII.
    {C, P} = cfg(#{}, [?OK]),
    [
        ?assertMatch(
            {error, #{code := invalid_request}}, ?N:send_email(C, (email())#{headers => Headers})
        )
     || Headers <- [
            maps:from_list([
                {<<"X-H", (integer_to_binary(N))/binary>>, <<"v">>}
             || N <- lists:seq(0, 15)
            ]),
            #{<<"X-Long">> => binary:copy(<<"a">>, 996)},
            #{<<"X-Name-Plus-Value">> => binary:copy(<<"a">>, 990)},
            #{<<"X-Tab">> => <<"a\tb">>},
            #{<<"X-Empty">> => <<>>},
            #{<<"Bad:Name">> => <<"v">>}
        ]
    ],
    ?assertEqual([], ?F:calls(P)).

config_set_and_passthrough_test() ->
    {C, P} = ?F:config(
        #{
            provider => ses,
            region => <<"eu-west-1">>,
            access_key_id => <<"AKID">>,
            secret_access_key => <<"s">>,
            from => <<"f@e.com">>,
            configuration_set_name => <<"default-set">>
        },
        [?OK]
    ),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{body => #{<<"ConfigurationSetName">> => <<"override-set">>}}
    }),
    %% Passthrough keys ride as given (SES's own PascalCase) and win over the config.
    ?assertEqual(
        <<"override-set">>, maps:get(<<"ConfigurationSetName">>, ?F:body_json(?F:last(P)))
    ),
    ?assertEqual(<<"email.eu-west-1.amazonaws.com">>, ?F:host_of(?F:last(P))).

config_set_from_config_test() ->
    {C, P} = cfg(#{configuration_set_name => <<"cs">>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(<<"cs">>, maps:get(<<"ConfigurationSetName">>, ?F:body_json(?F:last(P)))).

passthrough_query_is_signed_and_sent_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{query => #{<<"b">> => <<"x y">>, a => 1}}
    }),
    ?assertEqual(
        <<"https://email.us-east-1.amazonaws.com/v2/email/outbound-emails?a=1&b=x%20y">>,
        maps:get(url, ?F:last(P))
    ).

message_rejected_is_invalid_request_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(
            400,
            <<"{\"__type\":\"MessageRejected\",\"message\":\"Email address is not verified\"}">>
        )
    ]),
    ?assertMatch(
        {error, #{
            code := invalid_request,
            status := 400,
            provider_message := <<"Email address is not verified">>
        }},
        ?N:send_email(C, email())
    ).

error_code_sources_test_() ->
    Cases = [
        %% botocore RestJSONParser: x-amzn-ErrorType first, cut at ":".
        {
            #{
                <<"x-amzn-errortype">> =>
                    <<"SendingPausedException:http://internal.amazon.com/coral/com.amazon.ses/">>
            },
            <<"{\"message\":\"paused\"}">>,
            auth_failed
        },
        {#{<<"X-Amzn-ErrorType">> => <<"AccountSuspendedException">>}, <<"{}">>, auth_failed},
        %% Lowercase body `code` is read too (aws-sdk-js-v3 loadRestJsonErrorCode).
        {#{}, <<"{\"code\":\"SendingPausedException\",\"message\":\"paused\"}">>, auth_failed},
        {
            #{},
            <<"{\"__type\":\"com.amazonaws.ses#MailFromDomainNotVerifiedException\"}">>,
            invalid_request
        },
        {#{}, <<"{\"__type\":\"TooManyRequestsException\"}">>, rate_limited},
        {#{}, <<"{\"Code\":\"InvalidEmailAddress\",\"Message\":\"bad\"}">>, invalid_recipient}
    ],
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(400, Body, Headers)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {Headers, Body, Want} <- Cases
    ].

region_validated_before_signing_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{region => Region}, [?OK]),
            ?assertMatch({error, #{code := invalid_request}}, ?N:send_email(C, email())),
            ?assertEqual([], ?F:calls(P))
        end)
     || Region <- [
            <<"x.evil.com/">>,
            <<"us-east-1.attacker.net">>,
            <<>>,
            <<"-us-east-1">>,
            <<"123">>,
            <<"us-east-1\n">>
        ]
    ].

region_error_message_test() ->
    {C, _} = cfg(#{region => <<"x.evil.com/">>}, []),
    ?assertMatch(
        {error, #{
            message :=
                <<"Invalid SES region 'x.evil.com/'; expected an AWS region such as 'us-east-1'.">>
        }},
        ?N:send_email(C, email())
    ).

signed_headers_win_case_insensitively_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{
            headers => #{
                <<"authorization">> => <<"spoofed">>, <<"x-amz-date">> => <<"20000101T000000Z">>
            }
        }
    }),
    Names = ?F:header_names(?F:last(P)),
    ?assertEqual(1, length([N || N <- Names, N =:= <<"authorization">>])),
    ?assertEqual(1, length([N || N <- Names, N =:= <<"x-amz-date">>])),
    ?assertMatch(<<"AWS4-HMAC-SHA256 ", _/binary>>, ?F:header(?F:last(P), <<"Authorization">>)).

header_case_variant_replaces_connector_header_test() ->
    %% SES signs the headers; two Content-Type headers would let a transport
    %% send both and break the signature.
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => #{headers => #{<<"content-type">> => <<"application/json; charset=utf-8">>}}
    }),
    Req = ?F:last(P),
    ?assertEqual(1, length([N || N <- ?F:header_names(Req), N =:= <<"content-type">>])),
    ?assertEqual(
        <<"application/json; charset=utf-8">>, maps:get(<<"content-type">>, maps:get(headers, Req))
    ),
    ?assertNotEqual(nomatch, binary:match(?F:header(Req, <<"Authorization">>), <<"content-type">>)).

session_token_signed_test() ->
    {C, P} = cfg(#{session_token => fun() -> <<"SESSIONTOKEN">> end}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    Req = ?F:last(P),
    ?assertEqual(<<"SESSIONTOKEN">>, ?F:header(Req, <<"X-Amz-Security-Token">>)),
    ?assertNotEqual(
        nomatch, binary:match(?F:header(Req, <<"Authorization">>), <<"x-amz-security-token">>)
    ).

tags_become_email_tags_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{tags => [<<"welcome">>, <<"v_2">>]}),
    ?assertEqual(
        [
            #{<<"Name">> => <<"welcome">>, <<"Value">> => <<"welcome">>},
            #{<<"Name">> => <<"v_2">>, <<"Value">> => <<"v_2">>}
        ],
        maps:get(<<"EmailTags">>, ?F:body_json(?F:last(P)))
    ).

tag_outside_charset_rejected_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{}, [?OK]),
            ?assertMatch(
                {error, #{code := invalid_request}}, ?N:send_email(C, (email())#{tags => [Tag]})
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || Tag <- [<<"welcome email">>, <<"a.b">>, binary:copy(<<"x">>, 257), <<>>]
    ].

line_break_in_custom_header_rejected_not_rewritten_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{}, [?OK]),
            {error, E} = ?N:send_email(C, (email())#{headers => Headers}),
            ?assertMatch(#{code := invalid_request}, E),
            ?assertEqual(nomatch, binary:match(maps:get(message, E), <<"a\r\nb">>)),
            ?assertEqual([], ?F:calls(P))
        end)
     || Headers <- [
            #{<<"X-Ref">> => <<"a\r\nb">>}, #{<<"X-Ref">> => <<"a\n">>}, #{<<"X-Ref\n">> => <<"v">>}
        ]
    ].

status_level_mapping_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{\"message\":\"m\"}">>)]),
            ?assertMatch({error, #{code := Want, status := S}}, ?N:send_email(C, email()))
        end)
     || {S, Want} <- [
            {429, rate_limited},
            {454, rate_limited},
            {403, auth_failed},
            {401, auth_failed},
            {404, invalid_request},
            {500, provider_unavailable},
            {503, provider_unavailable},
            {409, unknown}
        ]
    ].

throttling_code_on_other_status_test() ->
    {C, _} = cfg(#{}, [?F:resp(409, <<"{\"__type\":\"ThrottlingException\"}">>)]),
    ?assertMatch({error, #{code := rate_limited}}, ?N:send_email(C, email())).
