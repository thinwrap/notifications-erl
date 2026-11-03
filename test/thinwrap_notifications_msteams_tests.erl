-module(thinwrap_notifications_msteams_tests).

%% Ported from the Python sibling's tests/test_msteams.py.

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_notifications_fake_transport).
-define(N, thinwrap_notifications).
-define(WEBHOOK, <<"https://acme.webhook.office.com/webhookb2/abc/IncomingWebhook/def">>).
%% A Workflows "When a Teams webhook request is received" trigger URL.
-define(WORKFLOW,
    <<"https://prod-12.westus.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke",
        "?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=xyz">>
).

cfg(Url, Responses) ->
    ?F:config(#{provider => 'ms-teams', webhook_url => Url}, Responses).

send(Url, Response) ->
    {C, _} = cfg(Url, [Response]),
    ?N:send_chat(C, #{body => <<"x">>}).

send_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"1">>)]),
    {ok, R} = ?N:send_chat(C, #{body => <<"hello team">>, to => <<"ignored">>}),
    %% Teams returns plain text "1" — no message id, raw carries the text.
    ?assertEqual(
        #{success => true, status => sent, provider_message_id => <<>>, raw => <<"1">>}, R
    ),
    Req = ?F:last(P),
    ?assertEqual(?WEBHOOK, maps:get(url, Req)),
    ?assertEqual(<<"application/json">>, ?F:header(Req, <<"Content-Type">>)),
    Payload = ?F:body_json(Req),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Payload)),
    [Att] = maps:get(<<"attachments">>, Payload),
    ?assertEqual(<<"application/vnd.microsoft.card.adaptive">>, maps:get(<<"contentType">>, Att)),
    ?assertEqual(
        #{
            <<"type">> => <<"AdaptiveCard">>,
            <<"$schema">> => <<"https://adaptivecards.io/schemas/adaptive-card.json">>,
            <<"version">> => <<"1.4">>,
            <<"body">> => [
                #{<<"type">> => <<"TextBlock">>, <<"text">> => <<"hello team">>, <<"wrap">> => true}
            ]
        },
        maps:get(<<"content">>, Att)
    ).

passthrough_replaces_attachments_test() ->
    {C, P} = cfg(?WEBHOOK, [?F:resp(200, <<"1">>)]),
    Custom = [#{<<"contentType">> => <<"custom">>, <<"content">> => #{<<"k">> => <<"v">>}}],
    {ok, _} = ?N:send_chat(C, #{
        body => <<"ignored">>,
        passthrough => #{body => #{attachments => Custom}, query => #{q => <<"1">>}}
    }),
    Req = ?F:last(P),
    ?assertEqual(Custom, maps:get(<<"attachments">>, ?F:body_json(Req))),
    %% The passthrough query is not forwarded.
    ?assertEqual(?WEBHOOK, maps:get(url, Req)).

requires_webhook_test_() ->
    [
        ?_test(begin
            {C, P} = cfg(Url, [?F:resp(200, <<"1">>)]),
            ?assertMatch({error, #{code := invalid_request, message := Msg}}, ?N:send_chat(C, #{})),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Url, Msg} <- [
            {<<>>, <<"MS Teams requires `webhookUrl` in config (webhook-URL-as-auth).">>},
            {<<"http://acme.webhook.office.com/x">>,
                <<"MS Teams webhook_url must be an https:// URL.">>}
        ]
    ].

%% 400 + "Invalid webhook URL" body is special-cased to auth_failed.
error_invalid_webhook_test() ->
    ?assertMatch(
        {error, #{
            code := auth_failed, status := 400, cause := #{<<"raw">> := <<"Invalid webhook URL">>}
        }},
        send(?WEBHOOK, ?F:resp(400, <<"Invalid webhook URL">>))
    ).

error_plain_400_test() ->
    ?assertMatch(
        {error, #{code := invalid_request, message := <<"Bad payload">>}},
        send(?WEBHOOK, ?F:resp(400, <<"Bad payload">>))
    ).

status_table_test_() ->
    [
        ?_assertMatch(
            {error, #{code := Want, status := S, message := Msg}}, send(?WEBHOOK, ?F:resp(S, Body))
        )
     || {S, Body, Want, Msg} <- [
            {401, <<>>, auth_failed, <<"MS Teams HTTP 401">>},
            {403, <<"no">>, auth_failed, <<"no">>},
            {404, <<>>, auth_failed, <<"MS Teams HTTP 404">>},
            {429, <<>>, rate_limited, <<"MS Teams HTTP 429">>},
            {500, <<>>, provider_unavailable, <<"MS Teams HTTP 500">>},
            {301, <<>>, unknown, <<"MS Teams HTTP 301">>}
        ]
    ].

%% Logic Apps Request trigger without a Response action: 202 ACCEPTED, no body.
workflows_202_empty_is_success_test() ->
    ?assertMatch(
        {ok, #{success := true, status := sent, raw := <<>>}}, send(?WORKFLOW, ?F:resp(202, <<>>))
    ).

%% 202 is the delivered case whatever the body, on a legacy host too.
the_202_is_success_on_legacy_host_too_test() ->
    ?assertMatch({ok, #{success := true}}, send(?WEBHOOK, ?F:resp(202, <<>>))),
    ?assertMatch(
        {ok, #{raw := <<"HTTP error 429">>}}, send(?WEBHOOK, ?F:resp(202, <<"HTTP error 429">>))
    ).

workflows_200_empty_is_success_test_() ->
    [
        ?_assertMatch({ok, #{success := true}}, send(Url, ?F:resp(200, <<>>)))
     || Url <- [
            ?WORKFLOW,
            <<"https://default123.environment.api.powerplatform.com/powerautomate/automations/direct/",
                "workflows/abc/triggers/manual/paths/invoke">>
        ]
    ].

legacy_200_other_text_fails_test() ->
    ?assertMatch(
        {error, #{
            status := 502,
            code := provider_unavailable,
            message := <<"Webhook Bad Request - Null or empty event">>
        }},
        send(?WEBHOOK, ?F:resp(200, <<"Webhook Bad Request - Null or empty event">>))
    ).

%% A legacy-host body that is not UTF-8 is not the "1" marker: a typed
%% failure, never a crash after the vendor accepted the request.
legacy_200_non_utf8_body_fails_test() ->
    ?assertMatch(
        {error, #{status := 502, code := provider_unavailable}},
        send(?WEBHOOK, ?F:resp(200, <<255, "1">>))
    ).

legacy_outlook_host_200_empty_fails_test() ->
    ?assertMatch(
        {error, #{status := 502, message := <<"MS Teams webhook failed">>}},
        send(<<"https://outlook.office.com/webhook/abc">>, ?F:resp(200, <<>>))
    ).

%% Python's str.strip(): surrounding Unicode whitespace around "1" is still
%% success; the host match ignores case, userinfo and port.
legacy_host_detection_and_strip_test_() ->
    [
        ?_assertMatch({ok, _}, send(?WEBHOOK, ?F:resp(200, <<" \n1\x{3000}"/utf8>>))),
        ?_assertMatch({ok, _}, send(?WEBHOOK, ?F:resp(200, <<"\x{a0}1\x{2003}"/utf8>>))),
        ?_assertMatch(
            {error, #{status := 502}},
            send(<<"https://u:p@ACME.Webhook.Office.COM:443/x">>, ?F:resp(200, <<"ok">>))
        ),
        ?_assertMatch(
            {error, #{status := 502}}, send(<<"HTTPS://Outlook.Office.com">>, ?F:resp(200, <<"2">>))
        ),
        %% Not a connector host: a look-alike suffix and a path mention.
        ?_assertMatch(
            {ok, _}, send(<<"https://evilwebhook.office.com/x">>, ?F:resp(200, <<"ok">>))
        ),
        ?_assertMatch(
            {ok, _}, send(<<"https://example.com/outlook.office.com">>, ?F:resp(200, <<"ok">>))
        ),
        ?_assertMatch({ok, _}, send(<<"https://[::1]:8443/x">>, ?F:resp(200, <<"ok">>)))
    ].

the_200_embedded_http_error_fails_with_that_status_test_() ->
    Body =
        <<"Microsoft Teams endpoint returned HTTP error 413 with ContextId tcid=0,server=msgapi">>,
    [
        ?_assertMatch(
            {error, #{
                status := 413, code := unknown, message := Body, cause := #{<<"raw">> := Body}
            }},
            send(Url, ?F:resp(200, Body))
        )
     || Url <- [?WEBHOOK, ?WORKFLOW]
    ].

the_200_embedded_429_is_rate_limited_test() ->
    Body = <<"Microsoft Teams endpoint returned http ERROR 429 with ContextId tcid=0">>,
    ?assertMatch(
        {error, #{code := rate_limited, status := 429}},
        send(?WEBHOOK, ?F:resp(200, Body, #{<<"Retry-After">> => <<"7">>}))
    ),
    {error, #{cause := Cause}} = send(
        ?WEBHOOK, ?F:resp(200, Body, #{<<"Retry-After">> => <<"7">>})
    ),
    ?assertEqual(7, maps:get(<<"retryAfterSeconds">>, Cause)).

the_200_embedded_400_invalid_webhook_is_auth_failed_test() ->
    ?assertMatch(
        {error, #{code := auth_failed, status := 400}},
        send(?WORKFLOW, ?F:resp(200, <<"HTTP error 400: Invalid webhook URL">>))
    ).

%% Each ill-formed sequence becomes U+FFFD exactly as Python's
%% `bytes.decode("utf-8", "replace")` does (expected values from CPython).
replacement_decoding_matches_python_test_() ->
    [
        ?_test(begin
            {C, _} = cfg(?WORKFLOW, [?F:resp(200, In)]),
            {ok, #{raw := Raw}} = ?N:send_chat(C, #{body => <<"x">>}),
            ?assertEqual(binary:decode_hex(Hex), Raw)
        end)
     || {In, Hex} <- [
            {<<16#e2, 16#82>>, <<"efbfbd">>},
            {<<16#e2, 16#82, "A">>, <<"efbfbd41">>},
            {<<16#ed, 16#a0, 16#80, "x">>, <<"efbfbdefbfbdefbfbd78">>},
            {<<16#f0, 16#9f, 16#98>>, <<"efbfbd">>},
            {<<16#f4, 16#90, 16#80, 16#80>>, <<"efbfbdefbfbdefbfbdefbfbd">>},
            {<<16#c0, 16#af>>, <<"efbfbdefbfbd">>},
            {<<"a", 16#e0, 16#80, "b">>, <<"61efbfbdefbfbd62">>},
            {<<"ok", 16#f0, 16#9f, 16#98, 16#80>>, <<"6f6bf09f9880">>},
            {<<16#f1, 16#80, 16#80, 16#c3, 16#a9>>, <<"efbfbdc3a9">>}
        ]
    ].
