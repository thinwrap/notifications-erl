-module(thinwrap_notifications_sparkpost).
-moduledoc false.

%% SparkPost email connector (v1 transmissions).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(US_BASE, <<"https://api.sparkpost.com">>).
-define(EU_BASE, <<"https://api.eu.sparkpost.com">>).
-define(TRANSMISSIONS_PATH, <<"/api/v1/transmissions">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I0) ->
    %% SparkPost's wire body is snake_case; rewrite the top-level passthrough
    %% keys so camelCase ones (campaignId, substitutionData) land as
    %% campaign_id / substitution_data.
    I = thinwrap_notifications_casing:transform_passthrough_body_top_level(I0, snake),
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I0),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Accept">> => <<"application/json">>,
            %% SparkPost auth is the RAW key — no "Bearer" or "Basic" prefix.
            <<"Authorization">> => thinwrap_notifications_input:secret(Config, api_key)
        },
        [],
        I
    ),
    Base =
        case thinwrap_notifications_util:cfg(Config, region) of
            <<"eu">> -> ?EU_BASE;
            _ -> ?US_BASE
        end,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(
            Config, <<Base/binary, ?TRANSMISSIONS_PATH/binary>>, Body, Headers, []
        ),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    Results = thinwrap_notifications_json:get(Raw, <<"results">>),
    Accepted = thinwrap_notifications_json:num(
        thinwrap_notifications_json:get(Results, <<"total_accepted_recipients">>)
    ),
    Rejected = thinwrap_notifications_json:num(
        thinwrap_notifications_json:get(Results, <<"total_rejected_recipients">>)
    ),
    %% A 2xx with every recipient rejected is surfaced as invalid_recipient, so
    %% callers handle it like the 4xx other providers send.
    (Results =/= undefined andalso Accepted == 0 andalso Rejected > 0) andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:new(invalid_recipient, #{
                status => Status,
                message => <<"SparkPost rejected all recipients">>,
                provider_message =>
                    <<"total_rejected_recipients=", (integer_to_binary(trunc(Rejected)))/binary,
                        ", total_accepted_recipients=0">>,
                cause => #{<<"raw">> => Raw}
            })
        ),
    thinwrap_notifications_util:result(
        queued,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Results, <<"id">>)),
        Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    First =
        case
            thinwrap_notifications_json:list(
                thinwrap_notifications_json:get(Raw, <<"errors">>)
            )
        of
            [F | _] -> F;
            _ -> undefined
        end,
    Msg = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(First, <<"message">>)
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, First), Msg
        )
    ).

build_body(Config, I) ->
    To = maps:get(to, I),
    %% The primary To has no header_to; each cc and bcc recipient carries
    %% address.header_to = the primary To, so their client shows the message as
    %% addressed to To.
    Recipients =
        [#{<<"address">> => #{<<"email">> => To}}] ++
            [
                #{<<"address">> => #{<<"email">> => E, <<"header_to">> => To}}
             || E <- maps:get(cc, I) ++ maps:get(bcc, I)
            ],
    FromObj = thinwrap_notifications_util:put_nonempty(
        <<"name">>,
        thinwrap_notifications_util:cfg(Config, sender_name),
        #{
            <<"email">> => thinwrap_notifications_util:first_non_empty([
                maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
            ])
        }
    ),
    Headers =
        case maps:get(cc, I) of
            %% Comma-joined, the CC list is visible to all recipients. BCC is
            %% deliberately NOT written as a header: those recipients ride in
            %% recipients[] + header_to and stay invisible.
            [] -> maps:get(headers, I);
            Cc -> (maps:get(headers, I))#{<<"CC">> => iolist_to_binary(lists:join(<<", ">>, Cc))}
        end,
    Atts = maps:get(attachments, I),
    Content = lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        #{<<"from">> => FromObj, <<"subject">> => maps:get(subject, I)},
        [
            {<<"html">>, maps:get(html, I)},
            {<<"text">>, maps:get(text, I)},
            %% SparkPost takes reply_to as a string, not an object.
            {<<"reply_to">>, maps:get(reply_to, I)},
            {<<"headers">>, Headers},
            {<<"attachments">>, [item(A) || #{content_id := <<>>} = A <- Atts]},
            {<<"inline_images">>, [item(A) || #{content_id := Cid} = A <- Atts, Cid =/= <<>>]}
        ]
    ),
    Body = #{<<"recipients">> => Recipients, <<"content">> => Content},
    case maps:get(tags, I) of
        [] ->
            Body;
        %% SparkPost has no top-level tags field; the convention is
        %% metadata.tags. Callers can override via passthrough body metadata.
        Tags ->
            Body#{<<"metadata">> => #{<<"tags">> => Tags}}
    end.

%% SparkPost requires `type` on both arrays. For inline_images, `name` "will
%% be inserted into the Content-ID header", so it carries the cid the HTML
%% references, not the filename.
item(#{filename := F, content := C, content_type := CT, content_id := Cid}) ->
    #{
        <<"name">> => thinwrap_notifications_util:first_non_empty([Cid, F]),
        <<"type">> => thinwrap_notifications_util:first_non_empty([
            CT, <<"application/octet-stream">>
        ]),
        <<"data">> => thinwrap_notifications_util:b64(C)
    }.

map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
%% 420 "Exceed Sending Limit — You exceeded your daily, monthly, or sandbox
%% sending limit": a quota, not a credential problem.
map_code(S, _) when S =:= 420; S =:= 429 -> rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(S, _) when S =:= 413; S =:= 422 -> invalid_request;
map_code(400, First) ->
    Message = string:lowercase(
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"message">>))
    ),
    Recipient =
        binary:match(Message, [<<"recipient">>, <<"address">>]) =/= nomatch orelse
            lists:member(
                thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"code">>)),
                [<<"1300">>, <<"1301">>, <<"1303">>]
            ),
    case Recipient of
        true -> invalid_recipient;
        false -> invalid_request
    end;
map_code(_, _) ->
    unknown.
