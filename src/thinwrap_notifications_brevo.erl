-module(thinwrap_notifications_brevo).
-moduledoc false.

%% Brevo email connector (v3/smtp/email).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.brevo.com/v3/smtp/email">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    %% Brevo's /v3/smtp/email has no first-class inline-cid mechanism, so an
    %% attachment with a content_id is rejected before any HTTP call.
    lists:any(fun(#{content_id := Cid}) -> Cid =/= <<>> end, maps:get(attachments, I)) andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<
                    "Brevo does not support attachment contentId (inline cid:-referenced "
                    "images). Use Brevo's templating system via _passthrough.body, or choose "
                    "a provider that supports cid (e.g. SendGrid, SES, Mailgun)."
                >>
            )
        ),
    %% No casing transform: Brevo's wire shape is already camelCase, so the
    %% passthrough body is forwarded as given.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Accept">> => <<"application/json">>,
            <<"api-key">> => thinwrap_notifications_input:secret(Config, api_key)
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"messageId">>)),
        Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Raw, <<"message">>)
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Msg), Msg
        )
    ).

build_body(Config, I) ->
    Sender = thinwrap_notifications_util:put_nonempty(
        <<"name">>,
        thinwrap_notifications_util:cfg(Config, sender_name),
        #{
            <<"email">> => thinwrap_notifications_util:first_non_empty([
                maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
            ])
        }
    ),
    Base = #{
        <<"sender">> => Sender,
        <<"to">> => [#{<<"email">> => maps:get(to, I)}],
        <<"subject">> => maps:get(subject, I)
    },
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"cc">>, [#{<<"email">> => E} || E <- maps:get(cc, I)]},
            {<<"bcc">>, [#{<<"email">> => E} || E <- maps:get(bcc, I)]},
            {<<"htmlContent">>, maps:get(html, I)},
            {<<"textContent">>, maps:get(text, I)},
            {<<"replyTo">>,
                case maps:get(reply_to, I) of
                    <<>> -> <<>>;
                    R -> #{<<"email">> => R}
                end},
            {<<"headers">>, maps:get(headers, I)},
            {<<"tags">>, maps:get(tags, I)},
            %% Brevo's attachment shape is {name, content}; the content type is
            %% implied by the filename and content_id is rejected above.
            {<<"attachment">>, [
                #{<<"name">> => F, <<"content">> => thinwrap_notifications_util:b64(C)}
             || #{filename := F, content := C} <- maps:get(attachments, I)
            ]}
        ]
    ).

%% Brevo's status -> code truth table.
map_code(S, _) when S =:= 401; S =:= 402; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(400, Msg) ->
    L = string:lowercase(Msg),
    case binary:match(L, [<<"recipient">>, <<"to[">>, <<"email address">>, <<"sender">>]) of
        nomatch -> invalid_request;
        _ -> invalid_recipient
    end;
map_code(404, _) ->
    invalid_request;
map_code(_, _) ->
    unknown.
