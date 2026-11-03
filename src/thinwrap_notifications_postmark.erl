-module(thinwrap_notifications_postmark).
-moduledoc false.

%% Postmark email connector (PascalCase JSON, X-Postmark-Server-Token).
%%
%% Postmark also answers 200 OK with ErrorCode != 0 on rejection; that is
%% re-raised as a 422-equivalent error.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://api.postmarkapp.com/email">>).
-define(TEMPLATE_ENDPOINT, <<"https://api.postmarkapp.com/email/withTemplate">>).

%% ErrorCodes per https://postmarkapp.com/developer/api/overview#error-codes.
-define(AUTH_ERROR_CODES, [
    %% bad or missing server/account token
    10,
    %% not in the current table; kept for older accounts that still return it
    405,
    %% account pending approval: recipients must share the From domain
    412,
    %% "This account is not approved to send email."
    413,
    %% invalid Server or Account
    422,
    %% IP not authorized
    1480
]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I0) ->
    %% Postmark's wire body is PascalCase; rewrite the caller's top-level
    %% passthrough keys so camelCase ones (templateModel) land as PascalCase
    %% (TemplateModel) alongside the connector-built fields.
    I = thinwrap_notifications_casing:transform_passthrough_body_top_level(I0, pascal),
    {Body0, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I0),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Accept">> => <<"application/json">>,
            <<"X-Postmark-Server-Token">> => thinwrap_notifications_input:secret(
                Config, server_token
            )
        },
        [],
        I
    ),
    %% Templates are sent only by POST /email/withTemplate ("TemplateId:
    %% Required if TemplateAlias is not specified"), whose body has no
    %% Subject/HtmlBody/TextBody: TemplateModel is "applied to the specified
    %% template to generate HtmlBody, TextBody, and Subject". Routing on the
    %% merged body lets a passthrough templateId/TemplateAlias select it; an
    %% empty alias names no template, so it stays a plain /email send.
    Templated =
        not lists:member(maps:get(<<"TemplateId">>, Body0, null), [null, undefined]) orelse
            case maps:get(<<"TemplateAlias">>, Body0, null) of
                A when is_binary(A), A =/= <<>> -> true;
                _ -> false
            end,
    {Endpoint, Body} =
        case Templated of
            false ->
                {?ENDPOINT, Body0};
            true ->
                B1 = maps:without([<<"Subject">>, <<"HtmlBody">>, <<"TextBody">>], Body0),
                %% TemplateModel is required on that endpoint; {} for a
                %% template without variables.
                B2 =
                    case maps:get(<<"TemplateModel">>, B1, null) of
                        null -> B1#{<<"TemplateModel">> => #{}};
                        _ -> B1
                    end,
                {?TEMPLATE_ENDPOINT, B2}
        end,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse raise_error(Status, RH, Raw),
    %% Postmark 200 with an embedded application-level error.
    case Raw of
        #{<<"ErrorCode">> := EC} ->
            thinwrap_notifications_json:num(EC) /= 0 andalso raise_error(422, RH, Raw);
        _ ->
            ok
    end,
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"MessageID">>)),
        case Raw of
            null -> #{};
            _ -> Raw
        end
    ).

%% Hand-builds Postmark's PascalCase wire body. Two outlier mappings: a single
%% Tag (Postmark accepts one — first tag wins) and the headers map -> a
%% [{Name, Value}] list.
build_body(Config, I) ->
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    Base = #{
        <<"From">> => thinwrap_notifications_util:format_mailbox(
            thinwrap_notifications_util:cfg(Config, sender_name), From
        ),
        <<"To">> => maps:get(to, I),
        <<"Subject">> => maps:get(subject, I)
    },
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"Cc">>, join(maps:get(cc, I))},
            {<<"Bcc">>, join(maps:get(bcc, I))},
            {<<"HtmlBody">>, maps:get(html, I)},
            {<<"TextBody">>, maps:get(text, I)},
            {<<"ReplyTo">>, maps:get(reply_to, I)},
            {<<"Headers">>, [
                #{<<"Name">> => N, <<"Value">> => V}
             || {N, V} <- lists:sort(maps:to_list(maps:get(headers, I)))
            ]},
            {<<"Tag">>,
                case maps:get(tags, I) of
                    [First | _] -> First;
                    [] -> <<>>
                end},
            {<<"MessageStream">>, thinwrap_notifications_util:cfg(Config, message_stream)},
            {<<"Attachments">>, [attachment(A) || A <- maps:get(attachments, I)]}
        ]
    ).

join(L) -> iolist_to_binary(lists:join(<<", ">>, L)).

attachment(#{filename := F, content := C, content_type := CT, content_id := Cid}) ->
    A = thinwrap_notifications_util:put_nonempty(<<"ContentType">>, CT, #{
        <<"Name">> => F, <<"Content">> => thinwrap_notifications_util:b64(C)
    }),
    %% Postmark requires the cid: prefix in ContentID for inline images.
    case Cid of
        <<>> -> A;
        _ -> A#{<<"ContentID">> => <<"cid:", Cid/binary>>}
    end.

%% A Postmark error, for both real HTTP errors and the embedded 200 +
%% ErrorCode != 0 ones (passed with status 422).
-spec raise_error(integer(), map(), term()) -> no_return().
raise_error(Status, RH, Raw) ->
    Msg = thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"Message">>)),
    ErrorCode = trunc(
        thinwrap_notifications_json:num(thinwrap_notifications_json:get(Raw, <<"ErrorCode">>))
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, ErrorCode, Msg), Msg
        )
    ).

%% The Postmark (HTTP status, ErrorCode) truth table. ErrorCode disambiguates
%% a 422 (and the embedded 200 errors, routed here as 422).
map_code(S, _, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _, _) ->
    rate_limited;
map_code(S, _, _) when S >= 500 -> provider_unavailable;
%% "Inactive recipient."
map_code(422, 406, _) ->
    invalid_recipient;
%% ErrorCode 300 "Send validation" covers "zero recipients, invalid address,
%% missing TextBody/HtmlBody, and recipient, metadata, attachment, or header
%% limits". Only an invalid To/Cc/Bcc address ("Invalid 'To' address", "Error
%% parsing 'Cc': Illegal email address") is the recipient's fault; a From
%% error or "Zero recipients specified" is the request's.
map_code(422, 300, Msg) ->
    case re:run(Msg, "'(?:to|cc|bcc)'", [caseless, unicode, {capture, none}]) of
        match -> invalid_recipient;
        nomatch -> invalid_request
    end;
map_code(422, EC, _) ->
    case lists:member(EC, ?AUTH_ERROR_CODES) of
        true -> auth_failed;
        %% 402/403 bad JSON or fields, 410 batch size, 411 attachment type,
        %% 1101 template, 1235/1236 message stream, and anything undocumented.
        false -> invalid_request
    end;
%% Postmark's other client errors are request errors: 404 "a resource/entity
%% that does not exist", 413 over the size limit, 415 missing headers.
map_code(S, _, _) when S >= 400 -> invalid_request;
map_code(_, _, _) ->
    unknown.
