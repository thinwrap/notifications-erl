-module(thinwrap_notifications_mailersend).
-moduledoc false.

%% MailerSend email connector (v1/email).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.mailersend.com/v1/email">>).
%% MailerSend caps a message at 5 tags; extra tags are dropped (first-5-wins
%% graceful degradation, >=90% baseline rule).
-define(TAG_LIMIT, 5).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I0) ->
    %% MailerSend's wire body is snake_case; rewrite the top-level passthrough
    %% keys so camelCase ones (templateId, sendAt, inReplyTo) land as
    %% template_id / send_at / in_reply_to.
    I = thinwrap_notifications_casing:transform_passthrough_body_top_level(I0, snake),
    Token = thinwrap_notifications_input:secret(Config, api_token),
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I0),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Token/binary>>,
            <<"X-Requested-With">> => <<"XMLHttpRequest">>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Decoded = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Decoded),
    %% 202 Accepted normally carries an empty body; the id is in X-Message-Id.
    %% A suppression-list hit is ALSO a 202, with {message, warnings:[{type,
    %% recipients, ...}]}: SOME_SUPPRESSED still sends to the rest, but
    %% ALL_SUPPRESSED means "Email is not sent" (and no X-Message-Id).
    Id = maps:get(<<"x-message-id">>, RH, <<>>),
    Warnings =
        case
            thinwrap_notifications_json:list(
                thinwrap_notifications_json:get(Decoded, <<"warnings">>)
            )
        of
            undefined -> [];
            W -> W
        end,
    lists:any(
        fun(W) ->
            thinwrap_notifications_json:str(thinwrap_notifications_json:get(W, <<"type">>)) =:=
                <<"ALL_SUPPRESSED">>
        end,
        Warnings
    ) andalso fail_all_suppressed(Status, RH, Decoded),
    Raw =
        case Decoded of
            #{} -> maps:merge(#{<<"messageId">> => Id}, Decoded);
            _ -> #{<<"messageId">> => Id}
        end,
    thinwrap_notifications_util:result(queued, Id, Raw).

%% ALL_SUPPRESSED on a 202: nothing was sent, so it is an invalid_recipient error.
-spec fail_all_suppressed(integer(), map(), term()) -> no_return().
fail_all_suppressed(Status, RH, Decoded) ->
    Text =
        case
            thinwrap_notifications_json:str(
                thinwrap_notifications_json:get(Decoded, <<"message">>)
            )
        of
            <<>> -> <<"MailerSend suppressed all recipients; email not sent">>;
            T -> T
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Decoded, invalid_recipient, Text
        )
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Decoded) ->
    Msg = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Decoded, <<"message">>)
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Decoded, map_code(Status, Decoded), Msg
        )
    ).

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
    Base = #{
        <<"from">> => FromObj,
        <<"to">> => [#{<<"email">> => maps:get(to, I)}],
        <<"subject">> => maps:get(subject, I)
    },
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"cc">>, [#{<<"email">> => E} || E <- maps:get(cc, I)]},
            {<<"bcc">>, [#{<<"email">> => E} || E <- maps:get(bcc, I)]},
            %% MailerSend takes reply_to as a single {email, name} object.
            {<<"reply_to">>,
                case maps:get(reply_to, I) of
                    <<>> -> <<>>;
                    R -> #{<<"email">> => R}
                end},
            {<<"html">>, maps:get(html, I)},
            {<<"text">>, maps:get(text, I)},
            {<<"headers">>, [
                #{<<"name">> => K, <<"value">> => V}
             || {K, V} <- lists:sort(maps:to_list(maps:get(headers, I)))
            ]},
            {<<"tags">>, lists:sublist(maps:get(tags, I), ?TAG_LIMIT)},
            {<<"attachments">>, [attachment(A) || A <- maps:get(attachments, I)]}
        ]
    ).

%% MailerSend's attachment object is {content, filename, disposition, id}; it
%% has no content-type field (the type is derived from the filename), so
%% content_type is not sent.
attachment(#{filename := F, content := C, content_id := Cid}) ->
    A = #{<<"filename">> => F, <<"content">> => thinwrap_notifications_util:b64(C)},
    case Cid of
        <<>> -> A;
        _ -> A#{<<"id">> => Cid, <<"disposition">> => <<"inline">>}
    end.

%% MailerSend's status -> code truth table. Validation failures come as 422
%% with an `errors` object keyed by dotted field path (from.email, to.0.email).
map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(422, Raw) ->
    Fields =
        case thinwrap_notifications_json:get(Raw, <<"errors">>) of
            #{} = Errs -> maps:keys(Errs);
            _ -> []
        end,
    case lists:any(fun recipient_field/1, Fields) of
        true ->
            invalid_recipient;
        false when Fields =/= [] ->
            invalid_request;
        false ->
            Message = string:lowercase(
                thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"message">>))
            ),
            case binary:match(Message, [<<"recipient">>, <<"email address">>]) of
                nomatch -> invalid_request;
                _ -> invalid_recipient
            end
    end;
map_code(400, _) ->
    invalid_request;
map_code(_, _) ->
    unknown.

recipient_field(<<"from.email">>) ->
    true;
recipient_field(F) ->
    lists:any(fun(P) -> string:prefix(F, P) =/= nomatch end, [
        <<"to.">>, <<"cc.">>, <<"bcc.">>, <<"reply_to.">>
    ]).
