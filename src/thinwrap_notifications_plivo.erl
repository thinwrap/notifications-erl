-module(thinwrap_notifications_plivo).
-moduledoc false.

%% Plivo SMS connector (JSON POST, Basic auth, snake_case).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    %% Passthrough keys are sent exactly as given: write Plivo's own
    %% snake_case names (powerpack_uuid, dlt_template_id, …).
    Src = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    HasPowerpack = present(<<"powerpack_uuid">>, thinwrap_notifications_passthrough:body(I)),
    (Src =/= <<>> orelse HasPowerpack) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<
                    "Plivo requires `from` (input or config) or a `powerpack_uuid` "
                    "passthrough field."
                >>
            )
        ),
    AuthId = thinwrap_notifications_util:cfg(Config, auth_id),
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        thinwrap_notifications_util:put_nonempty(<<"src">>, Src, #{
            <<"dst">> => maps:get(to, I), <<"text">> => maps:get(body, I)
        }),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => thinwrap_notifications_util:basic_auth(
                AuthId, thinwrap_notifications_input:secret(Config, auth_token)
            )
        },
        [],
        I
    ),
    %% The trailing slash is required by Plivo. Escaped as a path segment so a
    %% stray "/" or "?" cannot retarget the request.
    Endpoint =
        <<"https://api.plivo.com/v1/Account/",
            (thinwrap_notifications_util:quote(AuthId, <<>>))/binary, "/Message/">>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    %% message_uuid is an array; report message_uuid[0] (the full list is on
    %% raw's message_uuid).
    MessageId =
        case
            thinwrap_notifications_json:list(
                thinwrap_notifications_json:get(Raw, <<"message_uuid">>)
            )
        of
            [First | _] -> thinwrap_notifications_json:str(First);
            _ -> <<>>
        end,
    thinwrap_notifications_util:result(sent, MessageId, Raw).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"error">>)),
        <<"Plivo HTTP ", (integer_to_binary(Status))/binary>>
    ]),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

%% The key is set to a non-null value (the Python `is not None`).
present(K, M) -> not lists:member(maps:get(K, M, null), [null, undefined]).

map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
