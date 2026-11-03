-module(thinwrap_notifications_sns_tests).

%% Ported from the Python sibling's tests/test_sns.py, plus the SNS cases of
%% test_request_guards.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK_XML, <<
    "<?xml version=\"1.0\"?>"
    "<PublishResponse xmlns=\"http://sns.amazonaws.com/doc/2010-03-31/\">"
    "<PublishResult><MessageId>msg-abc-123</MessageId></PublishResult>"
    "<ResponseMetadata><RequestId>req-1</RequestId></ResponseMetadata>"
    "</PublishResponse>"
>>).
-define(AUTH_RE,
    "^AWS4-HMAC-SHA256 Credential=TESTKEYID/\\d{8}/us-east-1/sns/aws4_request, "
    "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=[0-9a-f]{64}$"
).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => sns,
                region => <<"us-east-1">>,
                access_key_id => <<"TESTKEYID">>,
                secret_access_key => <<"test-secret">>
            },
            Extra
        ),
        Responses
    ).

sms() -> #{to => <<"+15551234567">>, body => <<"hi">>}.

matches(B, Re) -> re:run(B, Re, [{capture, none}]) =:= match.

send_signs_and_publishes_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?OK_XML)]),
    {ok, R} = ?N:send_sms(C, #{to => <<"+15551234567">>, body => <<"hello">>}),
    ?assertMatch(#{success := true, status := sent, provider_message_id := <<"msg-abc-123">>}, R),
    ?assertEqual(?OK_XML, maps:get(raw, R)),
    Req = ?F:last(P),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"sns.us-east-1.amazonaws.com">>, ?F:host_of(Req)),
    ?assertEqual(<<"/">>, ?F:path_of(Req)),
    %% SigV4 headers are attached and not caller-overridable.
    ?assert(matches(?F:header(Req, <<"Authorization">>), ?AUTH_RE)),
    ?assert(matches(?F:header(Req, <<"X-Amz-Date">>), "^\\d{8}T\\d{6}Z$")),
    ?assertEqual(<<"sns.us-east-1.amazonaws.com">>, ?F:header(Req, <<"Host">>)),
    ?assertEqual(<<"application/x-www-form-urlencoded">>, ?F:header(Req, <<"Content-Type">>)),
    %% The signed payload hash is the hash of the bytes actually sent.
    ?assertEqual(
        binary:encode_hex(crypto:hash(sha256, maps:get(body, Req)), lowercase),
        ?F:header(Req, <<"X-Amz-Content-Sha256">>)
    ),
    ?assertEqual(
        <<"Action=Publish&Version=2010-03-31&Message=hello&PhoneNumber=%2B15551234567">>,
        maps:get(body, Req)
    ),
    Form = ?F:body_form(Req),
    ?assertEqual([<<"Publish">>], maps:get(<<"Action">>, Form)),
    ?assertEqual([<<"2010-03-31">>], maps:get(<<"Version">>, Form)),
    ?assertEqual([<<"hello">>], maps:get(<<"Message">>, Form)),
    ?assertEqual([<<"+15551234567">>], maps:get(<<"PhoneNumber">>, Form)),
    ?assertEqual(undefined, ?F:header(Req, <<"X-Amz-Security-Token">>)).

session_token_signed_test() ->
    {C, P} = cfg(#{session_token => fun() -> <<"STS-TOKEN">> end}, [?F:resp(200, ?OK_XML)]),
    {ok, _} = ?N:send_sms(C, sms()),
    Req = ?F:last(P),
    ?assertEqual(<<"STS-TOKEN">>, ?F:header(Req, <<"X-Amz-Security-Token">>)),
    ?assertNotEqual(
        nomatch, binary:match(?F:header(Req, <<"Authorization">>), <<"x-amz-security-token">>)
    ).

topic_arn_passthrough_no_phone_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?OK_XML)]),
    {ok, _} = ?N:send_sms(C, #{
        body => <<"broadcast">>,
        passthrough => #{body => #{'TopicArn' => <<"arn:aws:sns:us-east-1:1:topic">>}}
    }),
    Form = ?F:body_form(?F:last(P)),
    ?assertEqual([<<"arn:aws:sns:us-east-1:1:topic">>], maps:get(<<"TopicArn">>, Form)),
    ?assertNot(maps:is_key(<<"PhoneNumber">>, Form)).

passthrough_body_keys_verbatim_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?OK_XML)]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{
            body => #{
                <<"MessageAttributes.entry.1.Name">> => <<"AWS.SNS.SMS.SMSType">>,
                <<"Message">> => <<"replaced">>
            }
        }
    }),
    Form = ?F:body_form(?F:last(P)),
    ?assertEqual([<<"AWS.SNS.SMS.SMSType">>], maps:get(<<"MessageAttributes.entry.1.Name">>, Form)),
    ?assertEqual([<<"replaced">>], maps:get(<<"Message">>, Form)).

passthrough_query_folded_into_url_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?OK_XML)]),
    {ok, _} = ?N:send_sms(C, (sms())#{passthrough => #{query => #{'Extra' => <<"v w">>}}}),
    Req = ?F:last(P),
    ?assertEqual(<<"v w">>, ?F:qget(Req, <<"Extra">>)),
    ?assertMatch(<<"https://sns.us-east-1.amazonaws.com/?Extra=v%20w">>, maps:get(url, Req)).

requires_recipient_or_topic_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?OK_XML)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, #{body => <<"orphan">>})),
    ?assertEqual([], ?F:calls(P)).

error_auth_failed_via_xml_code_test() ->
    Err = <<
        "<ErrorResponse xmlns=\"http://sns.amazonaws.com/doc/2010-03-31/\">"
        "<Error><Type>Sender</Type><Code>SignatureDoesNotMatch</Code>"
        "<Message>signature mismatch</Message></Error>"
        "<RequestId>r</RequestId></ErrorResponse>"
    >>,
    {C, _} = cfg(#{}, [?F:resp(403, Err)]),
    {error, E} = ?N:send_sms(C, sms()),
    ?assertMatch(
        #{code := auth_failed, status := 403, provider_message := <<"signature mismatch">>}, E
    ),
    ?assertEqual(Err, maps:get(<<"raw">>, maps:get(cause, E))).

error_invalid_parameter_test() ->
    Err = <<
        "<ErrorResponse><Error><Code>InvalidParameter</Code>"
        "<Message>bad param</Message></Error></ErrorResponse>"
    >>,
    {C, _} = cfg(#{}, [?F:resp(400, Err)]),
    ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())).

error_code_table_test_() ->
    [
        ?_test(begin
            Xml =
                <<"<ErrorResponse><Error><Code>", Code/binary, "</Code></Error></ErrorResponse>">>,
            {C, _} = cfg(#{}, [?F:resp(S, Xml)]),
            {error, E} = ?N:send_sms(C, sms()),
            ?assertMatch(#{code := Want}, E),
            ?assertEqual(
                <<"SNS HTTP ", (integer_to_binary(S))/binary>>, maps:get(provider_message, E)
            )
        end)
     || {S, Code, Want} <- [
            {400, <<"InvalidClientTokenId">>, auth_failed},
            {400, <<"Throttling">>, rate_limited},
            {400, <<"ThrottlingException">>, rate_limited},
            {429, <<"x">>, rate_limited},
            {401, <<"x">>, auth_failed},
            {500, <<"InternalError">>, provider_unavailable},
            {404, <<"NotFound">>, invalid_request},
            {302, <<"InvalidParameterValue">>, invalid_request},
            {302, <<"x">>, unknown}
        ]
    ].

unterminated_xml_tag_is_empty_test() ->
    {C, _} = cfg(#{}, [?F:resp(200, <<"<MessageId>abc">>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>}}, ?N:send_sms(C, sms())),
    {C2, _} = cfg(#{}, [?F:resp(200, <<>>)]),
    ?assertMatch({ok, #{provider_message_id := <<>>, raw := <<>>}}, ?N:send_sms(C2, sms())).

region_validated_before_signing_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(#{region => Region}, [?F:resp(200, ?OK_XML)]),
            ?assertMatch({error, #{code := invalid_request}}, ?N:send_sms(C, sms())),
            ?assertEqual([], ?F:calls(P))
        end)
     || Region <- [
            <<"x.evil.com/">>,
            <<"us-east-1.attacker.net">>,
            <<>>,
            <<"999">>,
            %% test_request_guards.py: whole-string validators.
            <<"us-east-1\n">>
        ]
    ].

%% test_request_guards.py: SigV4 signs the headers; two Content-Type headers
%% would let a BYO transport send both and break the signature.
header_case_variant_replaces_connector_header_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?OK_XML)]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{
            headers => #{<<"content-type">> => <<"application/x-www-form-urlencoded">>}
        }
    }),
    Req = ?F:last(P),
    ?assertEqual(1, length([N || N <- ?F:header_names(Req), N =:= <<"content-type">>])),
    ?assertNotEqual(nomatch, binary:match(?F:header(Req, <<"Authorization">>), <<"content-type">>)).

caller_cannot_override_signed_headers_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, ?OK_XML)]),
    {ok, _} = ?N:send_sms(C, (sms())#{
        passthrough => #{headers => #{<<"authorization">> => <<"Bearer x">>}}
    }),
    Req = ?F:last(P),
    ?assertEqual(1, length([N || N <- ?F:header_names(Req), N =:= <<"authorization">>])),
    ?assert(matches(?F:header(Req, <<"Authorization">>), ?AUTH_RE)).

%% The Erlang analogue of the lone-surrogate case: not valid UTF-8.
invalid_utf8_is_invalid_request_test() ->
    {C, P} = cfg(#{}, [?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {error, #{code := invalid_request, cause := #{<<"raw">> := #{<<"exception">> := _}}}},
        ?N:send_sms(C, (sms())#{body => <<"hi", 16#ff>>})
    ),
    ?assertEqual([], ?F:calls(P)).
