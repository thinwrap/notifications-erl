-module(thinwrap_notifications_sendgrid).
-moduledoc false.

%% SendGrid email connector (v3 mail/send).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.sendgrid.com/v3/mail/send">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I0) ->
    Key = thinwrap_notifications_input:secret(Config, api_key),
    %% SendGrid's wire body is snake_case; rewrite the TOP-LEVEL keys of the
    %% caller's passthrough body (templateId -> template_id, sendAt -> send_at).
    %% Nested maps ride verbatim, so keys inside personalizations[]
    %% (dynamic_template_data) are written as SendGrid spells them.
    I = thinwrap_notifications_casing:transform_passthrough_body_top_level(I0, snake),
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I0),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Key/binary>>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    thinwrap_notifications_util:ok_status(Status) orelse
        error_out(Status, RH, thinwrap_notifications_json:decode(RB)),
    %% 202 Accepted carries an empty body; the id is in X-Message-Id.
    Id = maps:get(<<"x-message-id">>, RH, <<>>),
    thinwrap_notifications_util:result(queued, Id, #{<<"messageId">> => Id}).

build_body(Config, I) ->
    FromObj = thinwrap_notifications_util:put_nonempty(
        <<"name">>,
        thinwrap_notifications_util:cfg(Config, sender_name),
        #{
            <<"email">> => thinwrap_notifications_util:first_non_empty([
                maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
            ])
        }
    ),
    Personalization = lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        #{<<"to">> => [#{<<"email">> => maps:get(to, I)}]},
        [
            {<<"cc">>, [#{<<"email">> => E} || E <- maps:get(cc, I)]},
            {<<"bcc">>, [#{<<"email">> => E} || E <- maps:get(bcc, I)]}
        ]
    ),
    Content =
        [
            #{<<"type">> => <<"text/plain">>, <<"value">> => T}
         || T <- [maps:get(text, I)], T =/= <<>>
        ] ++
            [
                #{<<"type">> => <<"text/html">>, <<"value">> => H}
             || H <- [maps:get(html, I)], H =/= <<>>
            ],
    Base = #{
        <<"personalizations">> => [Personalization],
        <<"from">> => FromObj,
        <<"subject">> => maps:get(subject, I),
        <<"content">> => Content
    },
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"reply_to">>,
                case maps:get(reply_to, I) of
                    <<>> -> <<>>;
                    R -> #{<<"email">> => R}
                end},
            {<<"headers">>, maps:get(headers, I)},
            {<<"categories">>, maps:get(tags, I)},
            {<<"attachments">>, [attachment(A) || A <- maps:get(attachments, I)]}
        ]
    ).

attachment(#{filename := F, content := C, content_type := CT, content_id := Cid}) ->
    A = thinwrap_notifications_util:put_nonempty(<<"type">>, CT, #{
        <<"content">> => thinwrap_notifications_util:b64(C), <<"filename">> => F
    }),
    case Cid of
        <<>> -> A;
        _ -> A#{<<"content_id">> => Cid, <<"disposition">> => <<"inline">>}
    end.

-spec error_out(integer(), map(), term()) -> no_return().
error_out(Status, RH, Raw) ->
    First =
        case thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"errors">>)) of
            [F | _] -> F;
            _ -> undefined
        end,
    Msg = thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"message">>)),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status, First), Msg)
    ).

map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(413, _) ->
    invalid_request;
map_code(400, First) ->
    Field = thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"field">>)),
    Message = string:lowercase(
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"message">>))
    ),
    RecipientField =
        lists:member(Field, [<<"from.email">>, <<"reply_to">>, <<"reply_to.email">>]) orelse
            string:prefix(Field, <<"personalizations">>) =/= nomatch,
    case RecipientField orelse binary:match(Message, <<"email address">>) =/= nomatch of
        true -> invalid_recipient;
        false -> invalid_request
    end;
map_code(_, _) ->
    unknown.
