-module(thinwrap_notifications_mailtrap).
-moduledoc false.

%% Mailtrap email connector (sandbox / production send-email API).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(PRODUCTION_ENDPOINT, <<"https://send.api.mailtrap.io/api/send">>).
-define(SANDBOX_ENDPOINT, <<"https://sandbox.api.mailtrap.io/api/send">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I0) ->
    %% Mailtrap has no tags field: a non-empty tags list is rejected pre-flight
    %% (use passthrough body category instead).
    maps:get(tags, I0) =:= [] orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Mailtrap does not support tags at v1.0; use _passthrough.body.category instead">>
            )
        ),
    Url = endpoint(Config),
    %% Mailtrap's wire body is snake_case; rewrite the top-level passthrough
    %% keys so camelCase ones (templateUuid, templateVariables, customVariables)
    %% land as template_uuid / template_variables / custom_variables.
    I = thinwrap_notifications_casing:transform_passthrough_body_top_level(I0, snake),
    Token = thinwrap_notifications_input:secret(Config, api_token),
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I0),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Accept">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Token/binary>>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Url, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    Id =
        case
            thinwrap_notifications_json:list(
                thinwrap_notifications_json:get(Raw, <<"message_ids">>)
            )
        of
            [First | _] -> thinwrap_notifications_json:str(First);
            _ -> <<>>
        end,
    thinwrap_notifications_util:result(
        sent,
        Id,
        case Raw of
            null -> #{};
            _ -> Raw
        end
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Errs = [
        thinwrap_notifications_json:str(E)
     || E <- list_or_empty(
            thinwrap_notifications_json:list(
                thinwrap_notifications_json:get(Raw, <<"errors">>)
            )
        )
    ],
    Msg = iolist_to_binary(lists:join(<<"; ">>, Errs)),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Errs), Msg
        )
    ).

list_or_empty(undefined) -> [];
list_or_empty(L) -> L.

%% The send URL for `mode`. Sandbox URLs carry the inbox id in the path;
%% production uses a single host.
endpoint(Config) ->
    InboxId = thinwrap_notifications_util:cfg(Config, inbox_id),
    case thinwrap_notifications_util:cfg(Config, mode) of
        <<"sandbox">> ->
            InboxId =/= <<>> orelse
                thinwrap_notifications_error:fail(
                    thinwrap_notifications_error:invalid_request(
                        <<"Mailtrap sandbox mode requires inboxId in config">>
                    )
                ),
            %% Escaped: the id is a path segment, and a stray "/" or "?" would
            %% retarget the request.
            <<?SANDBOX_ENDPOINT/binary, "/",
                (thinwrap_notifications_util:quote(InboxId, <<>>))/binary>>;
        <<"production">> ->
            InboxId =:= <<>> orelse
                thinwrap_notifications_error:fail(
                    thinwrap_notifications_error:invalid_request(
                        <<
                            "Mailtrap production mode forbids inboxId in config "
                            "(it is sandbox-only)"
                        >>
                    )
                ),
            ?PRODUCTION_ENDPOINT;
        Mode ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:invalid_request(
                    <<"Mailtrap config.Mode must be 'sandbox' or 'production'; got \"", Mode/binary,
                        "\"">>
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
            %% Mailtrap wants reply_to as a single object (not an array).
            {<<"reply_to">>, email_obj(maps:get(reply_to, I))},
            {<<"html">>, maps:get(html, I)},
            {<<"text">>, maps:get(text, I)},
            %% Mailtrap accepts a flat map directly (no array reshape needed).
            {<<"headers">>, maps:get(headers, I)},
            {<<"attachments">>, [attachment(A) || A <- maps:get(attachments, I)]}
        ]
    ).

email_obj(<<>>) -> <<>>;
email_obj(E) -> #{<<"email">> => E}.

attachment(#{filename := F, content := C, content_type := CT, content_id := Cid}) ->
    A = thinwrap_notifications_util:put_nonempty(<<"type">>, CT, #{
        <<"filename">> => F, <<"content">> => thinwrap_notifications_util:b64(C)
    }),
    case Cid of
        <<>> -> A;
        _ -> A#{<<"content_id">> => Cid, <<"disposition">> => <<"inline">>}
    end.

%% Mailtrap's status -> code truth table. Validation failures come as 400 or
%% 422 with a string `errors[]` array; recipient detection scans each entry.
map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(S, Errs) when S =:= 422; S =:= 400 ->
    case lists:any(fun recipient_error/1, Errs) of
        true -> invalid_recipient;
        false -> invalid_request
    end;
map_code(_, _) ->
    unknown.

recipient_error(E) ->
    L = string:lowercase(E),
    lists:any(
        fun(Needle) -> binary:match(L, Needle) =/= nomatch end,
        [<<"recipient">>, <<"email">>, <<"to ">>, <<"from address">>]
    ).
