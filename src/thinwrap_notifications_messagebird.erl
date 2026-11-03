-module(thinwrap_notifications_messagebird).
-moduledoc false.

%% MessageBird (Bird) SMS connector (rest.messagebird.com JSON API).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://rest.messagebird.com/messages">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    Originator = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    Originator =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"MessageBird requires `from` (originator) in either the input or the config.">>
            )
        ),
    %% MessageBird requires recipients:[] even for a single recipient. Wire keys
    %% merge verbatim (no casing transform); provider-specific fields (type,
    %% reference, validity, datacoding, mclass, scheduledDatetime, …) ride in
    %% passthrough using their exact wire keys.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{
            <<"originator">> => Originator,
            <<"recipients">> => [maps:get(to, I)],
            <<"body">> => maps:get(body, I)
        },
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> =>
                <<"AccessKey ", (thinwrap_notifications_input:secret(Config, access_key))/binary>>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"id">>)), Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    %% Body shape: {errors:[{code,description,parameter}]}. The numeric
    %% code is preserved on cause.raw but not mapped — HTTP status
    %% drives classification.
    First =
        case
            thinwrap_notifications_json:list(
                thinwrap_notifications_json:get(Raw, <<"errors">>)
            )
        of
            [E | _] -> E;
            _ -> undefined
        end,
    Msg = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_json:str(
            thinwrap_notifications_json:get(First, <<"description">>)
        ),
        <<"MessageBird HTTP ", (integer_to_binary(Status))/binary>>
    ]),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
