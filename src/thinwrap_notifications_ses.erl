-module(thinwrap_notifications_ses).
-moduledoc false.

%% Amazon SES (v2) email connector — hand-rolled AWS SigV4, Simple content.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(PATH, <<"/v2/email/outbound-emails">>).

%% https://docs.aws.amazon.com/ses/latest/dg/header-fields.html: with Simple or
%% Templated content "you cannot set custom header content for headers that are
%% set by SES; therefore, the following headers are disallowed as custom
%% headers". Each maps to the input key that sets it, where one exists.
-define(DISALLOWED_HEADERS, #{
    <<"bcc">> => <<"bcc">>,
    <<"cc">> => <<"cc">>,
    <<"content-disposition">> => <<>>,
    <<"content-type">> => <<>>,
    <<"date">> => <<>>,
    <<"from">> => <<"from">>,
    <<"message-id">> => <<>>,
    <<"mime-version">> => <<>>,
    <<"reply-to">> => <<"reply_to">>,
    <<"return-path">> => <<>>,
    <<"subject">> => <<"subject">>,
    <<"to">> => <<"to">>
}).
%% SES v2 MessageHeader / MessageHeaderList model constraints.
-define(HEADER_NAME_RE, "^[!-9;-~]{1,126}\\z").
-define(HEADER_VALUE_RE, "^[ -~]{1,995}\\z").
%% SES v2 MessageTag: Name and Value "can only contain ASCII letters (a–z,
%% A–Z), numbers (0–9), underscores (_), or dashes (-)", at most 256 characters.
-define(TAG_RE, "^[A-Za-z0-9_-]{1,256}\\z").
-define(MAX_HEADERS, 15).
-define(MAX_HEADER_LINE, 996).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    Region = thinwrap_notifications_util:cfg(Config, region),
    ok = thinwrap_notifications_sigv4:validate_region(Region, <<"SES">>),
    %% Passthrough keys are sent exactly as given: write SES's own PascalCase
    %% names (ConfigurationSetName, EmailTags, …).
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I), #{<<"Content-Type">> => <<"application/json">>}, [], I
    ),
    Serialized = thinwrap_notifications_json:encode(Body),
    Host = <<"email.", Region/binary, ".amazonaws.com">>,
    CanonicalQuery = thinwrap_notifications_sigv4:build_canonical_query(Query),
    UrlPath =
        case CanonicalQuery of
            <<>> -> ?PATH;
            _ -> <<?PATH/binary, "?", CanonicalQuery/binary>>
        end,
    %% Caller-merged passthrough headers plus Content-Type participate in the
    %% signature; the AWS-managed headers returned by sign/1 win on collision.
    Signed = thinwrap_notifications_sigv4:sign(#{
        method => <<"POST">>,
        service => <<"ses">>,
        region => Region,
        host => Host,
        path => ?PATH,
        payload => Serialized,
        access_key_id => thinwrap_notifications_input:secret(Config, access_key_id),
        secret_access_key => thinwrap_notifications_input:secret(Config, secret_access_key),
        session_token => thinwrap_notifications_input:secret(Config, session_token),
        canonical_query => CanonicalQuery,
        signed => Headers
    }),
    ReqHeaders = thinwrap_notifications_sigv4:with_signed_headers(Headers, Signed),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_raw(
            Config,
            <<"https://", Host/binary, UrlPath/binary>>,
            <<"application/json">>,
            Serialized,
            ReqHeaders,
            []
        ),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"MessageId">>)),
        Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_json:str(
            thinwrap_notifications_json:get(Raw, <<"message">>)
        ),
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"Message">>))
    ]),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, error_code(RH, Raw)), Msg
        )
    ).

%% Hand-maps the input onto the SES v2 SendEmail body. SES's wire shape is
%% structural and irregular (Subject is {Data, Charset}, not a scalar), so the
%% PascalCase mapping is hand-coded rather than casing-transformed.
build_body(Config, I) ->
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    Destination = lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        #{<<"ToAddresses">> => [maps:get(to, I)]},
        [{<<"CcAddresses">>, maps:get(cc, I)}, {<<"BccAddresses">>, maps:get(bcc, I)}]
    ),
    MailBody = lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        #{},
        [
            {<<"Html">>, utf8_content(maps:get(html, I))},
            {<<"Text">>, utf8_content(maps:get(text, I))}
        ]
    ),
    Simple0 = #{
        <<"Subject">> => #{<<"Data">> => maps:get(subject, I), <<"Charset">> => <<"UTF-8">>},
        <<"Body">> => MailBody
    },
    Simple = lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Simple0,
        [
            {<<"Headers">>, simple_headers(maps:get(headers, I))},
            {<<"Attachments">>, [simple_attachment(A) || A <- maps:get(attachments, I)]}
        ]
    ),
    Base = #{
        %% SES: a Unicode "friendly from" name must use MIME encoded-word syntax.
        <<"FromEmailAddress">> => thinwrap_notifications_util:format_mailbox(
            thinwrap_notifications_util:cfg(Config, sender_name), From
        ),
        <<"Destination">> => Destination,
        <<"Content">> => #{<<"Simple">> => Simple}
    },
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"ReplyToAddresses">>, [R || R <- [maps:get(reply_to, I)], R =/= <<>>]},
            {<<"EmailTags">>, email_tags(maps:get(tags, I))},
            {<<"ConfigurationSetName">>,
                thinwrap_notifications_util:cfg(Config, configuration_set_name)}
        ]
    ).

utf8_content(<<>>) -> <<>>;
utf8_content(Data) -> #{<<"Data">> => Data, <<"Charset">> => <<"UTF-8">>}.

%% Baseline tags become SES `EmailTags` `{Name: tag, Value: tag}` (as in the
%% TypeScript and PHP siblings), checked against SES's tag charset before
%% sending rather than failing with a 400.
email_tags(Tags) ->
    [
        case re:run(T, ?TAG_RE, [{capture, none}]) of
            match ->
                #{<<"Name">> => T, <<"Value">> => T};
            nomatch ->
                thinwrap_notifications_error:fail(
                    thinwrap_notifications_error:invalid_request(
                        <<
                            "SES tags may contain only ASCII letters, digits, '_' and '-' "
                            "(1-256 characters)."
                        >>
                    )
                )
        end
     || T <- Tags
    ].

%% An attachment in the SES v2 `Attachment` shape (Simple content has carried
%% attachments since April 2025). RawContent is a blob, so over the HTTPS
%% interface it is base64.
simple_attachment(#{filename := F, content := C, content_type := CT, content_id := Cid}) ->
    A = thinwrap_notifications_util:put_nonempty(<<"ContentType">>, CT, #{
        <<"FileName">> => F, <<"RawContent">> => thinwrap_notifications_util:b64(C)
    }),
    case Cid of
        <<>> -> A#{<<"ContentDisposition">> => <<"ATTACHMENT">>};
        _ -> A#{<<"ContentId">> => Cid, <<"ContentDisposition">> => <<"INLINE">>}
    end.

%% The SES v2 Simple `Headers` list, rejecting before sending anything SES
%% would 400 on: a name SES sets itself, a name or value outside the model's
%% printable-ASCII patterns, more than 15 headers, or a name+value over 996.
simple_headers(Custom) when map_size(Custom) > ?MAX_HEADERS ->
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:invalid_request(
            iolist_to_binary([
                "SES accepts at most ",
                integer_to_list(?MAX_HEADERS),
                " custom headers; got ",
                integer_to_list(map_size(Custom)),
                "."
            ])
        )
    );
simple_headers(Custom) ->
    [simple_header(N, V) || {N, V} <- lists:sort(maps:to_list(Custom))].

simple_header(Name, Value0) ->
    %% A line break would be silently rewritten if stripped; SES would refuse
    %% the raw value anyway, so it is rejected (naming the header, not the value).
    has_line_break(Name) andalso
        invalid(<<"An SES custom header name contains a line break.">>),
    case maps:find(string:lowercase(Name), ?DISALLOWED_HEADERS) of
        {ok, Field} ->
            Hint =
                case Field of
                    <<>> -> <<>>;
                    _ -> <<"; set `", Field/binary, "` instead">>
                end,
            invalid(<<"SES does not allow a custom ", Name/binary, " header", Hint/binary, ".">>);
        _ ->
            ok
    end,
    matches(Name, ?HEADER_NAME_RE) orelse
        invalid(
            iolist_to_binary([
                "SES header name ",
                thinwrap_notifications_util:py_repr(Name),
                " must be 1-126 printable ASCII characters without ':'."
            ])
        ),
    has_line_break(Value0) andalso
        invalid(<<"SES header ", Name/binary, " contains a line break.">>),
    %% The value must be printable ASCII; RFC 2047 encoded-words carry the rest.
    Value =
        case lists:all(fun(C) -> C =< 16#7F end, binary_to_list(Value0)) of
            true -> Value0;
            false -> thinwrap_notifications_util:encoded_words(Value0)
        end,
    matches(Value, ?HEADER_VALUE_RE) orelse
        invalid(
            <<"SES header ", Name/binary,
                " needs a non-empty printable-ASCII value of at most 995 characters.">>
        ),
    byte_size(Name) + byte_size(Value) > ?MAX_HEADER_LINE andalso
        invalid(
            <<"SES header ", Name/binary, ": name plus value exceeds ",
                (integer_to_binary(?MAX_HEADER_LINE))/binary, " characters.">>
        ),
    #{<<"Name">> => Name, <<"Value">> => Value}.

has_line_break(B) -> binary:match(B, [<<"\r">>, <<"\n">>]) =/= nomatch.

matches(B, Re) -> re:run(B, Re, [{capture, none}]) =:= match.

-spec invalid(binary()) -> no_return().
invalid(Msg) ->
    thinwrap_notifications_error:fail(thinwrap_notifications_error:invalid_request(Msg)).

%% The restJson1 error code, read the way botocore and aws-sdk-js-v3 do: the
%% `x-amzn-ErrorType` header, else body `code`/`Code`, else `__type`. The raw
%% value can look like `MessageRejected:http://internal.amazon.com/...` or
%% `com.amazonaws...#MessageRejected`, so cut at `,` then `:` and keep what
%% follows the last `#`.
error_code(RH, Raw) ->
    Code0 =
        case maps:get(<<"x-amzn-errortype">>, RH, <<>>) of
            <<>> ->
                thinwrap_notifications_util:first_non_empty([
                    thinwrap_notifications_json:str(
                        thinwrap_notifications_json:get(Raw, <<"code">>)
                    ),
                    thinwrap_notifications_json:str(
                        thinwrap_notifications_json:get(Raw, <<"Code">>)
                    ),
                    thinwrap_notifications_json:str(
                        thinwrap_notifications_json:get(Raw, <<"__type">>)
                    )
                ]);
            H ->
                H
        end,
    [C1 | _] = binary:split(Code0, <<",">>),
    [C2 | _] = binary:split(C1, <<":">>),
    string:trim(lists:last(binary:split(C2, <<"#">>, [global]))).

%% The SES v2 (HTTP status, error-type code) truth table. Most SendEmail
%% exceptions share HTTP 400, so the code decides.
map_code(S, _) when S =:= 429; S =:= 454 -> rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(S, _) when S =:= 403; S =:= 401 -> auth_failed;
map_code(404, _) ->
    invalid_request;
map_code(400, Code) ->
    case Code of
        %% MessageRejected: "the message contains invalid content" — the
        %% request, not the recipient.
        <<"InvalidEmailAddress">> ->
            invalid_recipient;
        %% SendingPausedException (v2) and AccountSuspendedException are account
        %% states; the v1 AccountSendingPaused* names stay as aliases.
        _ when
            Code =:= <<"SendingPausedException">>;
            Code =:= <<"AccountSuspended">>;
            Code =:= <<"AccountSuspendedException">>;
            Code =:= <<"AccountSendingPaused">>;
            Code =:= <<"AccountSendingPausedException">>
        ->
            auth_failed;
        _ ->
            case throttling(Code) of
                true -> rate_limited;
                %% MessageRejected, MailFromDomainNotVerifiedException,
                %% LimitExceededException, BadRequestException,
                %% NotFoundException and anything undocumented.
                false -> invalid_request
            end
    end;
map_code(_, Code) ->
    case throttling(Code) of
        true -> rate_limited;
        false -> unknown
    end.

throttling(Code) ->
    lists:member(Code, [
        <<"Throttling">>, <<"ThrottlingException">>, <<"TooManyRequestsException">>
    ]).
