-module(thinwrap_notifications_core_tests).

%% Core: dispatch and the support table, misuse (badarg), the error model,
%% casing, passthrough, SigV4, shared encoders, the token-cache seam, and the
%% transport seam. Ported from the Python sibling's test_core.py and
%% test_dispatch_all.py (email cases; the SMS/push/chat golden sends land with
%% their connectors).

-include_lib("eunit/include/eunit.hrl").

-behaviour(thinwrap_notifications_transport).
-export([request/2]).

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(U, thinwrap_notifications_util).
-define(EMAIL, (email())).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

%% A test transport whose behaviour is chosen per test through its Opts.
request(#{url := Url}, {leak, Secret}) ->
    %% Mimics a client whose error embeds the full request URL.
    {error, {failed_connect, [{to_address, Url}, {secret, Secret}]}};
request(_Req, crash) ->
    erlang:error({tls_alert, <<"handshake failure">>});
request(_Req, timeout) ->
    {error, timeout};
request(_Req, malformed) ->
    {ok, #{status => <<"200">>}};
request(_Req, {connector_error, E}) ->
    {error, {connector_error, E}}.

%% ---------------------------------------------------------------------------
%% Dispatch and the support table (test_dispatch_all.py)

dispatch_configs() ->
    [
        %% Email
        {email, #{
            provider => ses,
            region => <<"us-east-1">>,
            access_key_id => <<"a">>,
            secret_access_key => <<"b">>
        }},
        {email, #{provider => resend, api_key => <<"k">>}},
        {email, #{provider => mailgun, api_key => <<"k">>, domain => <<"d">>}},
        {email, #{provider => sendgrid, api_key => <<"k">>}},
        {email, #{provider => postmark, server_token => <<"t">>}},
        {email, #{provider => mailersend, api_token => <<"t">>}},
        {email, #{provider => mailtrap, api_token => <<"t">>}},
        {email, #{provider => brevo, api_key => <<"k">>}},
        {email, #{provider => sparkpost, api_key => <<"k">>}},
        {email, #{provider => scaleway, secret_key => <<"s">>, project_id => <<"p">>}},
        %% SMS
        {sms, #{provider => vonage, api_key => <<"k">>, api_secret => <<"s">>}},
        {sms, #{provider => twilio, account_sid => <<"a">>, auth_token => <<"b">>}},
        {sms, #{provider => plivo, auth_id => <<"a">>, auth_token => <<"b">>}},
        {sms, #{
            provider => sns,
            region => <<"us-east-1">>,
            access_key_id => <<"a">>,
            secret_access_key => <<"b">>
        }},
        {sms, #{provider => sinch, service_plan_id => <<"p">>, api_token => <<"t">>}},
        {sms, #{provider => telnyx, api_key => <<"k">>}},
        {sms, #{provider => infobip, base_url => <<"https://x">>, api_key => <<"k">>}},
        {sms, #{provider => messagebird, access_key => <<"k">>}},
        {sms, #{provider => textmagic, username => <<"u">>, api_key => <<"k">>}},
        {sms, #{provider => d7networks, api_token => <<"t">>}},
        %% Push
        {push, #{
            provider => fcm,
            project_id => <<"p">>,
            client_email => <<"e">>,
            private_key => <<"k">>
        }},
        {push, #{provider => expo}},
        {push, #{
            provider => apns,
            team_id => <<"t">>,
            key_id => <<"k">>,
            private_key => <<"p">>,
            bundle_id => <<"b">>
        }},
        {push, #{provider => 'one-signal', app_id => <<"a">>, api_key => <<"k">>}},
        {push, #{provider => 'pusher-beams', instance_id => <<"i">>, secret_key => <<"s">>}},
        {push, #{provider => wonderpush, access_token => <<"t">>}},
        %% Chat
        {chat, #{provider => telegram, bot_token => <<"t">>}},
        {chat, #{provider => slack, webhook_url => <<"https://x">>}},
        {chat, #{
            provider => 'whatsapp-business',
            access_token => <<"t">>,
            phone_number_id => <<"p">>
        }},
        {chat, #{provider => discord, webhook_url => <<"https://x">>}},
        {chat, #{provider => 'ms-teams', webhook_url => <<"https://x">>}},
        {chat, #{provider => 'google-chat', webhook_url => <<"https://x">>}},
        {chat, #{provider => mattermost, webhook_url => <<"https://x">>}},
        {chat, #{provider => 'rocket-chat', webhook_url => <<"https://x">>}},
        {chat, #{provider => line, channel_access_token => <<"t">>}}
    ].

every_provider_config_validates_on_its_channel_test() ->
    Cfgs = dispatch_configs(),
    ?assertEqual(35, length(Cfgs)),
    [
        begin
            ?assert(?N:supports(P, Ch)),
            ?assertMatch(
                #{provider := P, transport := {thinwrap_notifications_httpc, #{}}},
                thinwrap_notifications_input:config(Ch, C)
            )
        end
     || {Ch, #{provider := P} = C} <- Cfgs
    ].

support_table_matches_python_registries_test() ->
    ?assertEqual(
        [
            brevo,
            mailersend,
            mailgun,
            mailtrap,
            postmark,
            resend,
            scaleway,
            sendgrid,
            ses,
            sparkpost
        ],
        ?N:providers(email)
    ),
    ?assertEqual(
        [d7networks, infobip, messagebird, plivo, sinch, sns, telnyx, textmagic, twilio, vonage],
        ?N:providers(sms)
    ),
    ?assertEqual([apns, expo, fcm, 'one-signal', 'pusher-beams', wonderpush], ?N:providers(push)),
    ?assertEqual(
        [
            discord,
            'google-chat',
            line,
            mattermost,
            'ms-teams',
            'rocket-chat',
            slack,
            telegram,
            'whatsapp-business'
        ],
        ?N:providers(chat)
    ),
    ?assertNot(?N:supports(twilio, email)),
    ?assertNot(?N:supports(nope, email)).

wrong_channel_is_badarg_test() ->
    ?assertError(
        {badarg, <<"twilio is not a email provider">>},
        ?N:send_email(#{provider => twilio, account_sid => <<"a">>, auth_token => <<"b">>}, ?EMAIL)
    ),
    ?assertError(
        {badarg, _}, ?N:send_sms(#{provider => sendgrid, api_key => <<"k">>}, #{to => <<"+1">>})
    ),
    ?assertError(
        {badarg, _}, ?N:send_push(#{provider => slack, webhook_url => <<"https://x">>}, #{})
    ),
    ?assertError(
        {badarg, _},
        ?N:send_chat(
            #{
                provider => fcm,
                project_id => <<"p">>,
                client_email => <<"e">>,
                private_key => <<"k">>
            },
            #{}
        )
    ).

%% Until a provider's module lands it is validated but cannot send; once it
%% lands this test simply skips it.
not_yet_implemented_provider_test() ->
    [
        ?assertError({provider_not_available, P}, send(Ch, C, #{}))
     || {Ch, #{provider := P} = C} <- dispatch_configs(),
        Ch =/= email,
        not module_available(P)
    ].

module_available(P) ->
    Mod = binary_to_atom(
        <<"thinwrap_notifications_",
            (binary:replace(atom_to_binary(P), <<"-">>, <<>>, [global]))/binary>>
    ),
    code:ensure_loaded(Mod) =:= {module, Mod}.

send(email, C, I) -> ?N:send_email(C, I);
send(sms, C, I) -> ?N:send_sms(C, I);
send(push, C, I) -> ?N:send_push(C, I);
send(chat, C, I) -> ?N:send_chat(C, I).

%% ---------------------------------------------------------------------------
%% Misuse is badarg, before any HTTP, never echoing a config value

misuse_test_() ->
    Good = #{provider => sendgrid, api_key => <<"SG.secret">>},
    Cases = [
        {"config not a map", undefined, ?EMAIL},
        {"config a binary", <<"sendgrid">>, ?EMAIL},
        {"config without provider", #{api_key => <<"SG.secret">>}, ?EMAIL},
        {"unknown provider", #{provider => nope, api_key => <<"SG.secret">>}, ?EMAIL},
        {"missing credential", #{provider => sendgrid}, ?EMAIL},
        {"unknown config key (typo)", #{provider => sendgrid, apikey => <<"SG.secret">>}, ?EMAIL},
        {"credential wrong type", #{provider => sendgrid, api_key => "SG.secret"}, ?EMAIL},
        {"non-credential wrong type", Good#{from => 'a@b.com'}, ?EMAIL},
        {"token_cache on a provider without one", Good#{token_cache => #{}}, ?EMAIL},
        {"transport not a tuple", Good#{transport => fun() -> ok end}, ?EMAIL},
        {"transport module missing", Good#{transport => {no_such_module_xyz, #{}}}, ?EMAIL},
        {"transport without request/2", Good#{transport => {lists, #{}}}, ?EMAIL},
        {"input not a map", Good, [{to, <<"u@e.com">>}]},
        {"unknown input key", Good, ?EMAIL#{body => <<"x">>}},
        {"to not a binary", Good, ?EMAIL#{to => "u@e.com"}},
        {"cc not a list of binaries", Good, ?EMAIL#{cc => <<"a@b.com">>}},
        {"headers values not binaries", Good, ?EMAIL#{headers => #{<<"X-A">> => 1}}},
        {"attachment without content", Good, ?EMAIL#{attachments => [#{filename => <<"f">>}]}},
        {"attachment unknown key", Good, ?EMAIL#{
            attachments => [#{filename => <<"f">>, content => <<"x">>, mime => <<"x">>}]
        }},
        {"passthrough unknown key", Good, ?EMAIL#{passthrough => #{form => #{}}}},
        {"passthrough body not a map", Good, ?EMAIL#{passthrough => #{body => [1]}}},
        {"passthrough query value a list", Good, ?EMAIL#{
            passthrough => #{query => #{q => [<<"a">>]}}
        }}
    ],
    [
        {Name,
            ?_test(begin
                {error, {badarg, Desc}} = catch_error(fun() -> ?N:send_email(C, I) end),
                ?assert(is_binary(Desc)),
                ?assertEqual(nomatch, binary:match(Desc, <<"SG.secret">>))
            end)}
     || {Name, C, I} <- Cases
    ].

catch_error(F) ->
    try F() of
        R -> {returned, R}
    catch
        error:E -> {error, E}
    end.

credential_fun_is_resolved_at_use_test() ->
    {C, P} = ?F:config(
        #{provider => sendgrid, api_key => fun() -> <<"SG.fun">> end, from => <<"a@b.com">>},
        [?F:resp(202, <<>>, #{<<"x-message-id">> => <<"m">>})]
    ),
    {ok, _} = ?N:send_email(C, ?EMAIL),
    ?assertEqual(<<"Bearer SG.fun">>, ?F:header(?F:last(P), <<"Authorization">>)),
    {C2, _} = ?F:config(#{provider => sendgrid, api_key => fun() -> nope end}, []),
    ?assertError({badarg, _}, ?N:send_email(C2, ?EMAIL)).

token_cache_shape_is_validated_test() ->
    Cfg = #{
        provider => fcm, project_id => <<"p">>, client_email => <<"e">>, private_key => <<"k">>
    },
    Good = #{get => fun(_) -> error end, set => fun(_, _, _) -> ok end},
    ?assertMatch(
        #{token_cache := Good}, thinwrap_notifications_input:config(push, Cfg#{token_cache => Good})
    ),
    [
        ?assertError(
            {badarg, _}, thinwrap_notifications_input:config(push, Cfg#{token_cache => Bad})
        )
     || Bad <- [
            #{get => fun(_) -> error end},
            {cache_mod, state},
            Good#{get => fun() -> error end},
            Good#{extra => 1}
        ]
    ].

%% ---------------------------------------------------------------------------
%% Token cache seam

token_cache_lookup_and_store_test() ->
    Self = self(),
    Now = thinwrap_notifications_token_cache:now_seconds(),
    Cache = fun(Reply) ->
        #{
            get => fun(K) ->
                Self ! {get, K},
                Reply
            end,
            set => fun(K, T, E) -> Self ! {set, K, T, E} end
        }
    end,
    TC = thinwrap_notifications_token_cache,
    ?assertEqual(miss, TC:lookup(#{}, <<"k">>)),
    ?assertEqual(
        {ok, <<"tok">>}, TC:lookup(#{token_cache => Cache({ok, {<<"tok">>, Now + 60}})}, <<"k">>)
    ),
    ?assertEqual(miss, TC:lookup(#{token_cache => Cache({ok, {<<"tok">>, Now - 1}})}, <<"k">>)),
    ?assertEqual(miss, TC:lookup(#{token_cache => Cache(error)}, <<"k">>)),
    ?assertError(
        {bad_token_cache_return, {tuple, 2}}, TC:lookup(#{token_cache => Cache({x, y})}, <<"k">>)
    ),
    ok = TC:store(#{}, <<"k">>, <<"tok">>, 1),
    ok = TC:store(#{token_cache => Cache(error)}, <<"k">>, <<"tok">>, 99),
    receive
        {set, <<"k">>, <<"tok">>, 99} -> ok
    after 1000 -> ?assert(false)
    end.

%% ---------------------------------------------------------------------------
%% Error model

retry_after_parse_test() ->
    E = thinwrap_notifications_error,
    ?assertEqual(120, E:parse_retry_after(<<"120">>)),
    ?assertEqual(undefined, E:parse_retry_after(<<"nope">>)),
    ?assertEqual(undefined, E:parse_retry_after(<<"">>)),
    ?assertEqual(undefined, E:parse_retry_after(<<"-5">>)),
    %% 1994-11-06T08:49:37Z = 784111777
    ?assertEqual(10, E:parse_retry_after(<<"Sun, 06 Nov 1994 08:49:37 GMT">>, 784111767)),
    ?assertEqual(0, E:parse_retry_after(<<"Sun, 06 Nov 1994 08:49:37 GMT">>, 784111800)),
    ?assertEqual(undefined, E:parse_retry_after(<<"Sun, 31 Feb 1994 08:49:37 GMT">>, 0)),
    ?assertEqual(undefined, E:parse_retry_after(<<"Sun, 06 Foo 1994 08:49:37 GMT">>, 0)).

vendor_error_cause_shape_test() ->
    Err = thinwrap_notifications_error:vendor_error(
        429,
        #{<<"retry-after">> => <<"42">>},
        #{<<"msg">> => <<"slow">>},
        rate_limited,
        <<"slow down">>
    ),
    ?assertEqual(
        #{
            code => rate_limited,
            status => 429,
            message => <<"slow down">>,
            provider_message => <<"slow down">>,
            cause => #{
                <<"raw">> => #{<<"msg">> => <<"slow">>},
                <<"retryAfter">> => <<"42">>,
                <<"retryAfterSeconds">> => 42
            }
        },
        Err
    ),
    %% Unparseable Retry-After rides raw only; an empty message gets a placeholder.
    E2 = thinwrap_notifications_error:vendor_error(
        503, #{<<"retry-after">> => <<"soon">>}, null, provider_unavailable, <<>>
    ),
    ?assertEqual(<<"<no vendor message>">>, maps:get(message, E2)),
    ?assertEqual(#{<<"raw">> => null, <<"retryAfter">> => <<"soon">>}, maps:get(cause, E2)),
    ?assertEqual(
        [
            invalid_recipient,
            rate_limited,
            auth_failed,
            provider_unavailable,
            invalid_request,
            unknown
        ],
        thinwrap_notifications_error:codes()
    ).

new_error_omits_undefined_test() ->
    ?assertEqual(
        #{code => unknown, message => <<"Connector error">>},
        thinwrap_notifications_error:new(unknown, #{status => undefined, cause => undefined})
    ).

assert_webhook_https_test() ->
    ?assertEqual(
        ok, thinwrap_notifications_error:assert_webhook_https(<<"HTTPS://x">>, <<"Slack">>)
    ),
    ?assertThrow(
        {thinwrap_notifications_error, #{
            code := invalid_request, message := <<"Slack webhook_url must be an https:// URL.">>
        }},
        thinwrap_notifications_error:assert_webhook_https(<<"http://x">>, <<"Slack">>)
    ).

%% ---------------------------------------------------------------------------
%% Casing and passthrough

casing_test() ->
    C = thinwrap_notifications_casing,
    ?assertEqual(<<"dynamic_template_data">>, C:to_casing(<<"dynamicTemplateData">>, snake)),
    ?assertEqual(<<"MessagingServiceSid">>, C:to_casing(<<"messagingServiceSid">>, pascal)),
    ?assertEqual(<<"http_server">>, C:to_casing(<<"HTTPServer">>, snake)),
    ?assertEqual(<<"httpServer">>, C:to_casing(<<"HTTP_SERVER">>, camel)),
    ?assertEqual(<<"http-server">>, C:to_casing(<<"httpServer">>, kebab)),
    ?assertEqual(<<"HTTP_SERVER">>, C:to_casing(<<"http server">>, constant)),
    ?assertEqual(<<>>, C:to_casing(<<"__">>, camel)),
    Nested = C:transform_keys(#{<<"outerKey">> => #{<<"innerKey">> => 1}}, snake, true),
    ?assertEqual(#{<<"outer_key">> => #{<<"inner_key">> => 1}}, Nested),
    %% Shallow: nested data maps pass verbatim.
    Shallow = C:transform_keys(
        #{dynamicTemplateData => #{<<"firstName">> => <<"Ann">>}}, snake, false
    ),
    ?assertEqual(#{<<"dynamic_template_data">> => #{<<"firstName">> => <<"Ann">>}}, Shallow),
    ?assertEqual(#{}, C:transform_passthrough_body_top_level(#{}, snake)).

deep_merge_passthrough_test() ->
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        #{<<"a">> => 1, <<"nested">> => #{<<"x">> => 1}},
        #{<<"H">> => <<"1">>},
        [{<<"q0">>, <<"orig">>}],
        #{
            passthrough => #{
                body => #{b => 2, nested => #{y => 2}},
                headers => #{<<"H2">> => <<"2">>},
                query => #{q => v, q0 => 7}
            }
        }
    ),
    ?assertEqual(
        #{<<"a">> => 1, <<"b">> => 2, <<"nested">> => #{<<"x">> => 1, <<"y">> => 2}}, Body
    ),
    ?assertEqual(#{<<"H">> => <<"1">>, <<"H2">> => <<"2">>}, Headers),
    ?assertEqual([{<<"q0">>, <<"7">>}, {<<"q">>, <<"v">>}], Query).

passthrough_header_override_is_case_insensitive_test() ->
    {_, H, _} = thinwrap_notifications_passthrough:merge(
        #{}, #{<<"Content-Type">> => <<"a">>}, [], #{
            passthrough => #{headers => #{'content-type' => <<"b">>}}
        }
    ),
    ?assertEqual(#{<<"content-type">> => <<"b">>}, H).

merge_form_keeps_order_test() ->
    Fields = [{<<"a">>, <<"1">>}, {<<"m">>, #{<<"x">> => 1}}, {<<"b">>, <<"2">>}],
    ?assertEqual(
        [
            {<<"a">>, <<"9">>},
            {<<"m">>, #{<<"x">> => 1, <<"y">> => 2}},
            {<<"b">>, <<"2">>},
            {<<"c">>, 3}
        ],
        thinwrap_notifications_passthrough:merge_form(Fields, #{
            passthrough => #{body => #{a => <<"9">>, c => 3, m => #{y => 2}}}
        })
    ).

%% ---------------------------------------------------------------------------
%% SigV4 (byte-identical to the Python sibling's signer)

sigv4_matches_python_vector_test() ->
    S = thinwrap_notifications_sigv4,
    CQ = S:build_canonical_query([{<<"b">>, <<"x y">>}, {<<"a">>, <<"1~*">>}]),
    ?assertEqual(<<"a=1~%2A&b=x%20y">>, CQ),
    P = #{
        method => <<"POST">>,
        service => <<"ses">>,
        region => <<"us-east-1">>,
        host => <<"email.us-east-1.amazonaws.com">>,
        path => <<"/v2/email/outbound-emails">>,
        payload => <<"{\"x\":1}">>,
        access_key_id => <<"AKIDEXAMPLE">>,
        secret_access_key => <<"wSecret">>,
        session_token => <<"TOK">>,
        canonical_query => CQ,
        signed => #{<<"Content-Type">> => <<"application/json">>, <<"X-Ref">> => <<"  a   b ">>},
        now => {{2026, 1, 2}, {3, 4, 5}}
    },
    H = S:sign(P),
    ?assertEqual(H, S:sign(P)),
    ?assertEqual(
        #{
            <<"Host">> => <<"email.us-east-1.amazonaws.com">>,
            <<"X-Amz-Date">> => <<"20260102T030405Z">>,
            <<"X-Amz-Content-Sha256">> =>
                <<"5041bf1f713df204784353e82f6a4a535931cb64f1f4b4a5aeaffcb720918b22">>,
            <<"Authorization">> =>
                <<
                    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260102/us-east-1/ses/aws4_request, "
                    "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;"
                    "x-amz-security-token;x-ref, "
                    "Signature=a6cab77c7e42e4fd5048095c8be3e7f0c21bcfa230318e4cccaa74056b5b7605"
                >>,
            <<"X-Amz-Security-Token">> => <<"TOK">>
        },
        H
    ).

sigv4_structure_without_token_test() ->
    H = thinwrap_notifications_sigv4:sign(#{
        method => <<"POST">>,
        service => <<"ses">>,
        region => <<"us-east-1">>,
        host => <<"email.us-east-1.amazonaws.com">>,
        path => <<"/v2/email/outbound-emails">>,
        payload => <<"{\"x\":1}">>,
        access_key_id => <<"AKIDEXAMPLE">>,
        secret_access_key => <<"wSecret">>,
        %% Unsignable headers are never folded into the signature.
        signed => #{<<"Content-Type">> => <<"application/json">>, <<"User-Agent">> => <<"x">>}
    }),
    Auth = maps:get(<<"Authorization">>, H),
    ?assertMatch(<<"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/", _/binary>>, Auth),
    ?assertNotEqual(
        nomatch,
        binary:match(Auth, <<"SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,">>)
    ),
    [_, Sig] = binary:split(Auth, <<"Signature=">>),
    ?assertEqual(64, byte_size(Sig)),
    ?assertNot(maps:is_key(<<"X-Amz-Security-Token">>, H)).

with_signed_headers_test() ->
    ?assertEqual(
        #{<<"Authorization">> => <<"sig">>, <<"X-Other">> => <<"1">>},
        thinwrap_notifications_sigv4:with_signed_headers(
            #{<<"authorization">> => <<"spoofed">>, <<"X-Other">> => <<"1">>},
            #{<<"Authorization">> => <<"sig">>}
        )
    ).

%% ---------------------------------------------------------------------------
%% Shared encoders

urlencode_matches_python_test() ->
    %% urllib.parse.urlencode([("a b", "x~*é+&")])
    ?assertEqual(
        <<"a+b=x~%2A%C3%A9%2B%26">>, ?U:urlencode([{<<"a b">>, <<"x~*é+&"/utf8>>}])
    ),
    ?assertEqual(<<"a%2Fb%3F">>, ?U:quote(<<"a/b?">>, <<>>)),
    ?assertEqual(<<"1:a%2Fb">>, ?U:quote(<<"1:a/b">>, <<":">>)),
    ?assertEqual(
        <<"https://h/p?a=1&b=x">>, ?U:build_url(<<"https://h/p?a=1">>, [{<<"b">>, <<"x">>}])
    ),
    ?assertEqual(<<"https://h/p">>, ?U:build_url(<<"https://h/p">>, [])).

encode_form_test() ->
    ?assertEqual(
        <<"a=1&a=2&m=%7B%22k%22%3A1%7D&f=1.5&i=2&t=true&n=x">>,
        ?U:encode_form([
            {<<"a">>, [<<"1">>, 2]},
            {<<"skip">>, null},
            {<<"m">>, #{<<"k">> => 1}},
            {<<"f">>, 1.5},
            {<<"i">>, 2.0},
            {<<"t">>, true},
            {<<"n">>, x}
        ])
    ).

format_mailbox_test() ->
    ?assertEqual(
        <<"=?UTF-8?B?Wm/Dqw==?= <z@x.com>">>, ?U:format_mailbox(<<>>, <<"Zoë <z@x.com>"/utf8>>)
    ),
    ?assertEqual(<<"Acme <a@b.com>">>, ?U:format_mailbox(<<"Acme">>, <<"a@b.com">>)),
    ?assertEqual(<<"a@b.com">>, ?U:format_mailbox(<<>>, <<"a@b.com">>)),
    ?assertEqual(<<"Bob <j@x.com>">>, ?U:format_mailbox(<<"Bob">>, <<"<j@x.com>">>)),
    ?assertEqual(
        <<"\"Doe, Jane\" <j@x.com>">>, ?U:format_mailbox(<<"Bob">>, <<"\"Doe, Jane\" <j@x.com>">>)
    ),
    %% CR/LF in a display name cannot inject a header.
    ?assertEqual(<<"\"A. B\" <a@b.com>">>, ?U:format_mailbox(<<"A.\r\nB">>, <<"a@b.com">>)).

encoded_words_split_on_character_boundaries_test() ->
    ?assertEqual(
        <<
            "=?UTF-8?B?w5xuw69jw7hkw6kgU2VuZGVyIMOcbsOvY8O4ZMOpIFNlbmRlciDDnG7Dr2M=?= "
            "=?UTF-8?B?w7hkw6kgU2VuZGVyIA==?="
        >>,
        ?U:encoded_words(<<"Ünïcødé Sender Ünïcødé Sender Ünïcødé Sender "/utf8>>)
    ).

response_text_test() ->
    ?assertEqual(<<>>, ?U:response_text(null)),
    ?assertEqual(<<"12">>, ?U:response_text(12.0)),
    ?assertEqual(<<"12.5">>, ?U:response_text(12.5)),
    ?assertEqual(<<"12345">>, ?U:response_text(12345)),
    ?assertEqual(<<"true">>, ?U:response_text(true)),
    ?assertEqual(<<"{\"a\":1}">>, ?U:response_text(#{<<"a">> => 1})),
    ?assertEqual(<<>>, ?U:response_text({not_json})).

py_repr_test() ->
    ?assertEqual(<<"'us-east-1\\n'">>, ?U:py_repr(<<"us-east-1\n">>)),
    ?assertEqual(<<"\"it's\"">>, ?U:py_repr(<<"it's">>)),
    ?assertEqual(<<"'\\x00\\\\'">>, ?U:py_repr(<<0, "\\">>)).

%% ---------------------------------------------------------------------------
%% Golden SendGrid sends (test_core.py)

sendgrid_cfg(Extra, Responses) ->
    ?F:config(maps:merge(#{provider => sendgrid, api_key => <<"SG.k">>}, Extra), Responses).

golden_sendgrid_send_test() ->
    {C, P} = sendgrid_cfg(
        #{from => <<"from@acme.com">>, sender_name => <<"Acme">>},
        [?F:resp(202, <<>>, #{<<"X-Message-Id">> => <<"msg-123">>})]
    ),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        text => <<"hello">>,
        html => <<"<b>hi</b>">>,
        cc => [<<"cc@x.com">>]
    }),
    ?assertEqual(
        #{
            success => true,
            status => queued,
            provider_message_id => <<"msg-123">>,
            raw => #{<<"messageId">> => <<"msg-123">>}
        },
        R
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"https://api.sendgrid.com/v3/mail/send">>, maps:get(url, Last)),
    ?assertEqual(post, maps:get(method, Last)),
    ?assertEqual(<<"Bearer SG.k">>, ?F:header(Last, <<"Authorization">>)),
    ?assertEqual(<<"application/json">>, ?F:header(Last, <<"Content-Type">>)),
    Body = ?F:body_json(Last),
    ?assertEqual(
        #{<<"email">> => <<"from@acme.com">>, <<"name">> => <<"Acme">>}, maps:get(<<"from">>, Body)
    ),
    ?assertEqual(
        [
            #{<<"type">> => <<"text/plain">>, <<"value">> => <<"hello">>},
            #{<<"type">> => <<"text/html">>, <<"value">> => <<"<b>hi</b>">>}
        ],
        maps:get(<<"content">>, Body)
    ),
    ?assertEqual(
        [
            #{
                <<"to">> => [#{<<"email">> => <<"user@example.com">>}],
                <<"cc">> => [#{<<"email">> => <<"cc@x.com">>}]
            }
        ],
        maps:get(<<"personalizations">>, Body)
    ).

golden_sendgrid_snake_case_passthrough_test() ->
    {C, P} = sendgrid_cfg(#{from => <<"a@b.com">>}, [
        ?F:resp(202, <<>>, #{<<"x-message-id">> => <<"m1">>})
    ]),
    {ok, _} = ?N:send_email(C, #{
        to => <<"u@e.com">>,
        subject => <<"s">>,
        text => <<"x">>,
        passthrough => #{body => #{<<"dynamicTemplateData">> => #{<<"firstName">> => <<"Sam">>}}}
    }),
    %% Top-level key cased to snake_case; nested template-data keys VERBATIM.
    ?assertEqual(
        #{<<"firstName">> => <<"Sam">>},
        maps:get(<<"dynamic_template_data">>, ?F:body_json(?F:last(P)))
    ).

golden_sendgrid_error_test() ->
    {C, _} = sendgrid_cfg(#{from => <<"a@b.com">>}, [
        ?F:resp(401, <<"{\"errors\":[{\"message\":\"unauthorized\"}]}">>)
    ]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 401, provider_message := <<"unauthorized">>}},
        ?N:send_email(C, ?EMAIL)
    ).

sendgrid_attachments_reply_to_tags_test() ->
    {C, P} = sendgrid_cfg(#{}, [?F:resp(202, <<>>)]),
    {ok, #{provider_message_id := <<>>}} = ?N:send_email(C, ?EMAIL#{
        reply_to => <<"r@x.com">>,
        bcc => [<<"b@x.com">>],
        tags => [<<"t1">>],
        headers => #{<<"X-A">> => <<"1">>},
        attachments => [
            #{filename => <<"a.txt">>, content => <<"a">>},
            #{
                filename => <<"logo.png">>,
                content => <<"png">>,
                content_type => <<"image/png">>,
                content_id => <<"logo">>
            }
        ]
    }),
    B = ?F:body_json(?F:last(P)),
    ?assertEqual(#{<<"email">> => <<"r@x.com">>}, maps:get(<<"reply_to">>, B)),
    ?assertEqual([<<"t1">>], maps:get(<<"categories">>, B)),
    ?assertEqual(#{<<"X-A">> => <<"1">>}, maps:get(<<"headers">>, B)),
    ?assertEqual(#{<<"email">> => <<>>}, maps:get(<<"from">>, B)),
    ?assertEqual(
        [
            #{<<"content">> => <<"YQ==">>, <<"filename">> => <<"a.txt">>},
            #{
                <<"content">> => <<"cG5n">>,
                <<"filename">> => <<"logo.png">>,
                <<"type">> => <<"image/png">>,
                <<"content_id">> => <<"logo">>,
                <<"disposition">> => <<"inline">>
            }
        ],
        maps:get(<<"attachments">>, B)
    ).

sendgrid_error_mapping_test_() ->
    Cases = [
        {403, <<"{}">>, auth_failed},
        {429, <<"{}">>, rate_limited},
        {502, <<"{}">>, provider_unavailable},
        {413, <<"{}">>, invalid_request},
        {400, <<"{\"errors\":[{\"field\":\"personalizations.0.to\",\"message\":\"x\"}]}">>,
            invalid_recipient},
        {400, <<"{\"errors\":[{\"field\":\"reply_to.email\",\"message\":\"x\"}]}">>,
            invalid_recipient},
        {400, <<"{\"errors\":[{\"message\":\"Does not contain a valid Email Address\"}]}">>,
            invalid_recipient},
        {400, <<"{\"errors\":[{\"field\":\"subject\",\"message\":\"x\"}]}">>, invalid_request},
        {404, <<"{}">>, unknown}
    ],
    [
        ?_test(begin
            {C, _} = sendgrid_cfg(#{}, [?F:resp(S, B)]),
            ?assertMatch({error, #{code := Want, status := S}}, ?N:send_email(C, ?EMAIL))
        end)
     || {S, B, Want} <- Cases
    ].

%% ---------------------------------------------------------------------------
%% Transport seam

transport_error_does_not_leak_url_or_credentials_test() ->
    Secret = <<"AKIASECRETKEYID">>,
    C = #{
        provider => ses,
        region => <<"us-east-1">>,
        access_key_id => Secret,
        secret_access_key => <<"s">>,
        from => <<"a@b.com">>,
        transport => {?MODULE, {leak, Secret}}
    },
    {error, E} = ?N:send_email(C, ?EMAIL#{passthrough => #{query => #{key => <<"QUERYSECRET">>}}}),
    ?assertEqual(
        #{
            code => provider_unavailable,
            message => <<"Upstream transport error (failed_connect)">>,
            provider_message => <<"Upstream transport error (failed_connect)">>,
            cause => #{<<"raw">> => #{<<"exception">> => <<"failed_connect">>}}
        },
        E
    ),
    Text = iolist_to_binary(io_lib:format("~p", [E])),
    [
        ?assertEqual(nomatch, binary:match(Text, S))
     || S <- [Secret, <<"QUERYSECRET">>, <<"amazonaws">>]
    ].

transport_crash_and_timeout_are_provider_unavailable_test() ->
    Base = #{provider => sendgrid, api_key => <<"k">>},
    ?assertMatch(
        {error, #{
            code := provider_unavailable, message := <<"Upstream transport error (tls_alert)">>
        }},
        ?N:send_email(Base#{transport => {?MODULE, crash}}, ?EMAIL)
    ),
    {error, E} = ?N:send_email(Base#{transport => {?MODULE, timeout}}, ?EMAIL),
    ?assertMatch(
        #{code := provider_unavailable, message := <<"Upstream transport error (timeout)">>}, E
    ),
    ?assertNot(maps:is_key(status, E)).

transport_connector_error_passes_through_test() ->
    Ready = thinwrap_notifications_error:invalid_request(<<"no">>),
    ?assertEqual(
        {error, Ready},
        ?N:send_email(
            #{
                provider => sendgrid,
                api_key => <<"k">>,
                transport => {?MODULE, {connector_error, Ready}}
            },
            ?EMAIL
        )
    ).

bad_transport_return_is_a_caller_bug_test() ->
    ?assertError(
        {bad_transport_return, ?MODULE, {ok, [status]}},
        ?N:send_email(
            #{provider => sendgrid, api_key => <<"k">>, transport => {?MODULE, malformed}}, ?EMAIL
        )
    ).

fake_transport_queue_test() ->
    {C, P} = ?F:config(#{provider => sendgrid, api_key => <<"k">>}, []),
    %% An empty queue answers 200 with an empty body.
    ?assertMatch({ok, #{provider_message_id := <<>>}}, ?N:send_email(C, ?EMAIL)),
    {C2, P2} = ?F:config(#{provider => sendgrid, api_key => <<"k">>}, [{error, econnrefused}]),
    ?assertMatch({error, #{code := provider_unavailable}}, ?N:send_email(C2, ?EMAIL)),
    ?assertEqual(1, length(?F:calls(P2))),
    ok = ?F:stop(P),
    ok = ?F:stop(P2).
