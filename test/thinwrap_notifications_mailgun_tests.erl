-module(thinwrap_notifications_mailgun_tests).

%% Ported from the Python sibling's tests/test_mailgun.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(OK, ?F:resp(200, <<"{\"id\":\"x\"}">>)).

cfg(Extra, Responses) ->
    ?F:config(
        maps:merge(
            #{
                provider => mailgun,
                api_key => <<"k">>,
                domain => <<"mg.example.com">>,
                from => <<"f@e.com">>
            },
            Extra
        ),
        Responses
    ).

email() -> #{to => <<"u@e.com">>, subject => <<"s">>, text => <<"t">>}.

contains(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

send_test() ->
    {C, P} = cfg(
        #{api_key => <<"key-123">>, from => <<"from@acme.com">>, sender_name => <<"Acme">>},
        [?F:resp(200, <<"{\"id\":\"<msg@mg.example.com>\",\"message\":\"Queued. Thank you.\"}">>)]
    ),
    {ok, R} = ?N:send_email(C, #{
        to => <<"user@example.com">>,
        subject => <<"Hi">>,
        text => <<"hi">>,
        html => <<"<b>hi</b>">>,
        cc => [<<"c1@example.com">>, <<"c2@example.com">>],
        bcc => [<<"b@example.com">>],
        reply_to => <<"reply@acme.com">>,
        tags => [<<"a">>, <<"b">>, <<"c">>, <<"d">>]
    }),
    ?assertMatch(
        #{success := true, status := queued, provider_message_id := <<"<msg@mg.example.com>">>}, R
    ),
    Req = ?F:last(P),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"api.mailgun.net">>, ?F:host_of(Req)),
    ?assertEqual(<<"/v3/mg.example.com/messages">>, ?F:path_of(Req)),
    ?assertEqual(
        <<"Basic ", (base64:encode(<<"api:key-123">>))/binary>>, ?F:header(Req, <<"Authorization">>)
    ),
    ?assertEqual(<<"application/x-www-form-urlencoded">>, ?F:header(Req, <<"Content-Type">>)),
    Single = ?F:body_form_single(Req),
    ?assertEqual(<<"Acme <from@acme.com>">>, maps:get(<<"from">>, Single)),
    ?assertEqual(<<"user@example.com">>, maps:get(<<"to">>, Single)),
    ?assertEqual(<<"Hi">>, maps:get(<<"subject">>, Single)),
    ?assertEqual(<<"c1@example.com,c2@example.com">>, maps:get(<<"cc">>, Single)),
    ?assertEqual(<<"b@example.com">>, maps:get(<<"bcc">>, Single)),
    ?assertEqual(<<"reply@acme.com">>, maps:get(<<"h:Reply-To">>, Single)),
    ?assertEqual(<<"<b>hi</b>">>, maps:get(<<"html">>, Single)),
    %% Tags truncated to 3 repeated o:tag fields.
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], maps:get(<<"o:tag">>, ?F:body_form(Req))).

eu_region_test() ->
    {C, P} = cfg(#{region => <<"eu">>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(<<"api.eu.mailgun.net">>, ?F:host_of(?F:last(P))).

custom_base_url_username_and_escaped_domain_test() ->
    {C, P} = cfg(
        #{base_url => <<"https://mg.proxy.example">>, username => <<"me">>, domain => <<"a/b?c">>},
        [?OK]
    ),
    {ok, _} = ?N:send_email(C, email()),
    Req = ?F:last(P),
    ?assertEqual(<<"https://mg.proxy.example/v3/a%2Fb%3Fc/messages">>, maps:get(url, Req)),
    ?assertEqual(
        <<"Basic ", (base64:encode(<<"me:k">>))/binary>>, ?F:header(Req, <<"Authorization">>)
    ).

multipart_attachment_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        tags => [<<"welcome">>],
        attachments => [
            #{filename => <<"note.txt">>, content_type => <<"text/plain">>, content => <<"hello">>}
        ]
    }),
    Req = ?F:last(P),
    CT = ?F:header(Req, <<"Content-Type">>),
    ?assertMatch(<<"multipart/form-data; boundary=----=_Part_", _/binary>>, CT),
    <<"multipart/form-data; boundary=", Boundary/binary>> = CT,
    ?assertEqual(35, byte_size(Boundary)),
    Body = maps:get(body, Req),
    ?assert(
        contains(Body, <<"name=\"attachment\"; filename=\"note.txt\"\r\nContent-Type: text/plain">>)
    ),
    ?assert(contains(Body, <<"name=\"o:tag\"\r\n\r\nwelcome\r\n">>)),
    ?assert(contains(Body, <<"hello">>)),
    ?assert(contains(Body, <<"name=\"to\"\r\n\r\nu@e.com\r\n">>)),
    ?assertMatch({_, _}, binary:match(Body, <<"--", Boundary/binary, "--\r\n">>)).

multipart_header_name_sanitized_test() ->
    %% A caller custom-header NAME carrying a quote + CRLF must not break out of
    %% the name="..." multipart parameter or inject a rogue MIME header line.
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        headers => #{<<"X-Evil\"\r\nInjected">> => <<"yes">>},
        attachments => [#{filename => <<"f.txt">>, content => <<"data">>}]
    }),
    Body = maps:get(body, ?F:last(P)),
    ?assertNot(contains(Body, <<"\r\nInjected">>)),
    ?assert(contains(Body, <<"name=\"h:X-Evil\\\" Injected\"">>)),
    ?assert(contains(Body, <<"filename=\"f.txt\"\r\nContent-Type: application/octet-stream">>)).

error_mapping_test() ->
    {C, _} = cfg(#{}, [
        ?F:resp(
            400,
            <<"{\"message\":\"'to' parameter is not a valid email address. please check documentation\"}">>
        )
    ]),
    ?assertMatch(
        {error, #{code := invalid_recipient}}, ?N:send_email(C, (email())#{to => <<"bad">>})
    ).

auth_error_mapping_test() ->
    {C, _} = cfg(#{api_key => <<"bad">>}, [
        ?F:resp(401, <<"{\"message\":\"Invalid private key\"}">>)
    ]),
    ?assertMatch({error, #{code := auth_failed}}, ?N:send_email(C, email())).

status_table_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(#{}, [?F:resp(S, <<"{\"message\":\"x\"}">>)]),
            ?assertMatch({error, #{code := Want}}, ?N:send_email(C, email()))
        end)
     || {S, Want} <- [
            %% Mailgun API overview: 403 "Valid credentials but access denied".
            {403, auth_failed},
            {402, auth_failed},
            {429, rate_limited},
            {500, provider_unavailable},
            {400, invalid_request},
            {404, invalid_request},
            {413, invalid_request},
            {409, unknown}
        ]
    ].

http_base_url_rejected_before_sending_test() ->
    %% The Basic credential would cross the network in cleartext over http://.
    {C, P} = cfg(#{base_url => <<"http://api.mailgun.net">>}, [?OK]),
    ?assertMatch(
        {error, #{
            code := invalid_request, message := <<"Mailgun base_url must be an https:// URL.">>
        }},
        ?N:send_email(C, email())
    ),
    ?assertEqual([], ?F:calls(P)).

reply_to_header_deduplicated_case_insensitively_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        reply_to => <<"typed@acme.com">>,
        headers => #{<<"reply-to">> => <<"header@acme.com">>, <<"X-Tag">> => <<"a">>}
    }),
    Form = ?F:body_form(?F:last(P)),
    ?assertEqual([<<"h:Reply-To">>], [
        K
     || K <- maps:keys(Form), string:lowercase(K) =:= <<"h:reply-to">>
    ]),
    ?assertEqual([<<"typed@acme.com">>], maps:get(<<"h:Reply-To">>, Form)),
    ?assertEqual([<<"a">>], maps:get(<<"h:X-Tag">>, Form)).

map_is_json_and_list_repeats_on_both_paths_test() ->
    %% Mailgun: t:variables is "A valid JSON-encoded dictionary"; o:tag repeats.
    Pt = #{
        body => #{
            <<"t:variables">> => #{<<"name">> => <<"Ada">>, <<"n">> => 1},
            <<"o:tag">> => [<<"x">>, <<"y">>]
        }
    },
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{passthrough => Pt}),
    Form = ?F:body_form(?F:last(P)),
    [Vars] = maps:get(<<"t:variables">>, Form),
    ?assertEqual(#{<<"name">> => <<"Ada">>, <<"n">> => 1}, json:decode(Vars)),
    ?assertEqual([<<"x">>, <<"y">>], maps:get(<<"o:tag">>, Form)),
    {ok, _} = ?N:send_email(C, (email())#{
        passthrough => Pt, attachments => [#{filename => <<"f.txt">>, content => <<"d">>}]
    }),
    Body = maps:get(body, ?F:last(P)),
    ?assert(
        contains(Body, <<"name=\"t:variables\"\r\n\r\n{\"name\":\"Ada\",\"n\":1}\r\n">>) orelse
            contains(Body, <<"name=\"t:variables\"\r\n\r\n{\"n\":1,\"name\":\"Ada\"}\r\n">>)
    ),
    ?assertEqual(2, length(binary:matches(Body, <<"name=\"o:tag\"">>))).

passthrough_o_tag_extended_by_typed_tags_test() ->
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, (email())#{
        tags => [<<"t">>], passthrough => #{body => #{<<"o:tag">> => <<"x">>}}
    }),
    ?assertEqual([<<"x">>, <<"t">>], maps:get(<<"o:tag">>, ?F:body_form(?F:last(P)))).

from_name_quoted_test() ->
    {C, P} = cfg(#{sender_name => <<"Acme, Inc.">>}, [?OK]),
    {ok, _} = ?N:send_email(C, email()),
    ?assertEqual(
        <<"\"Acme, Inc.\" <f@e.com>">>, maps:get(<<"from">>, ?F:body_form_single(?F:last(P)))
    ).

inline_part_filename_is_content_id_test() ->
    %% Mailgun derives an inline image's Content-ID from the part's filename, so
    %% <img src="cid:logo"> resolves only when the inline filename is "logo".
    {C, P} = cfg(#{}, [?OK]),
    {ok, _} = ?N:send_email(C, #{
        to => <<"u@e.com">>,
        subject => <<"s">>,
        html => <<"<img src=\"cid:logo\">">>,
        attachments => [
            #{
                filename => <<"logo.png">>,
                content => <<"png">>,
                content_type => <<"image/png">>,
                content_id => <<"logo">>
            },
            #{filename => <<"a.txt">>, content => <<"a">>}
        ]
    }),
    Body = maps:get(body, ?F:last(P)),
    ?assert(contains(Body, <<"name=\"inline\"; filename=\"logo\"">>)),
    ?assert(contains(Body, <<"name=\"attachment\"; filename=\"a.txt\"">>)).
