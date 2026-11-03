-module(thinwrap_notifications_scaleway).
-moduledoc false.

%% Scaleway Transactional Email (TEM) connector (v1alpha1).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(API_BASE, <<"https://api.scaleway.com/transactional-email/v1alpha1">>).
-define(DEFAULT_REGION, <<"fr-par">>).
-define(DEFAULT_ATTACHMENT_MIME, <<"application/octet-stream">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I0) ->
    %% Scaleway's wire body is snake_case; rewrite the top-level passthrough
    %% keys so camelCase ones (scheduledAt) land as scheduled_at.
    I = thinwrap_notifications_casing:transform_passthrough_body_top_level(I0, snake),
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I0),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Accept">> => <<"application/json">>,
            <<"X-Auth-Token">> => thinwrap_notifications_input:secret(Config, secret_key)
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, endpoint(Config), Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    %% Scaleway accepts for delivery asynchronously: `queued`. A 2xx with an
    %% empty or missing emails array is still a success.
    Id =
        case thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"emails">>)) of
            [E | _] ->
                thinwrap_notifications_util:first_non_empty([
                    thinwrap_notifications_json:str(
                        thinwrap_notifications_json:get(E, <<"message_id">>)
                    ),
                    thinwrap_notifications_json:str(thinwrap_notifications_json:get(E, <<"id">>))
                ]);
            _ ->
                <<>>
        end,
    thinwrap_notifications_util:result(
        queued,
        Id,
        case Raw of
            null -> #{};
            _ -> Raw
        end
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg =
        case
            thinwrap_notifications_json:str(
                thinwrap_notifications_json:get(Raw, <<"message">>)
            )
        of
            <<>> ->
                case
                    thinwrap_notifications_json:list(
                        thinwrap_notifications_json:get(Raw, <<"errors">>)
                    )
                of
                    [First | _] ->
                        thinwrap_notifications_json:str(
                            thinwrap_notifications_json:get(First, <<"message">>)
                        );
                    _ ->
                        <<>>
                end;
            M ->
                M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

%% The region (default fr-par) goes into the PATH — Scaleway uses one host for
%% every region. Region ids are "<country>-<city>" (fr-par, nl-ams, pl-waw);
%% anything else is rejected rather than interpolated.
endpoint(Config) ->
    Region = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_util:cfg(Config, region), ?DEFAULT_REGION
    ]),
    case re:run(Region, "^[a-z]{2}-[a-z]{3}\\z", [{capture, none}]) of
        match ->
            <<?API_BASE/binary, "/regions/", Region/binary, "/emails">>;
        nomatch ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:invalid_request(
                    iolist_to_binary([
                        "Invalid Scaleway region ",
                        thinwrap_notifications_util:py_repr(Region),
                        "; expected an id such as 'fr-par'."
                    ])
                )
            )
    end.

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
    %% additional_headers: the headers map as [{key, value}]. reply_to has no
    %% first-class Scaleway field — it goes in first as a Reply-To header.
    HeaderPairs =
        [
            #{<<"key">> => <<"Reply-To">>, <<"value">> => R}
         || R <- [maps:get(reply_to, I)], R =/= <<>>
        ] ++
            [
                #{<<"key">> => K, <<"value">> => V}
             || {K, V} <- lists:sort(maps:to_list(maps:get(headers, I)))
            ],
    Base = #{
        <<"from">> => FromObj,
        <<"to">> => [#{<<"email">> => maps:get(to, I)}],
        <<"subject">> => maps:get(subject, I),
        <<"project_id">> => thinwrap_notifications_util:cfg(Config, project_id)
    },
    %% No Scaleway field exists for tags or an attachment's content_id (inline
    %% images): both are dropped.
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"cc">>, [#{<<"email">> => E} || E <- maps:get(cc, I)]},
            {<<"bcc">>, [#{<<"email">> => E} || E <- maps:get(bcc, I)]},
            {<<"text">>, maps:get(text, I)},
            {<<"html">>, maps:get(html, I)},
            {<<"additional_headers">>, HeaderPairs},
            %% Scaleway requires a non-empty mime type on every attachment.
            {<<"attachments">>, [
                #{
                    <<"name">> => F,
                    <<"type">> => thinwrap_notifications_util:first_non_empty([
                        CT, ?DEFAULT_ATTACHMENT_MIME
                    ]),
                    <<"content">> => thinwrap_notifications_util:b64(C)
                }
             || #{filename := F, content := C, content_type := CT} <- maps:get(attachments, I)
            ]}
        ]
    ).

%% Scaleway has no body-level error code, so the HTTP status is the only signal.
map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
