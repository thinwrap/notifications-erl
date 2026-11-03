-module(thinwrap_notifications_telegram).
-moduledoc false.

%% Telegram Bot API chat connector (POST /bot<token>/sendMessage).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{to := To, body := Text} = I) ->
    To =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Telegram requires `to` (chat_id or @channelname).">>
            )
        ),
    %% Passthrough keys are sent exactly as given: write the Bot API's own
    %% snake_case names (parse_mode, message_thread_id, reply_markup).
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        #{<<"chat_id">> => To, <<"text">> => Text},
        #{<<"Content-Type">> => <<"application/json">>},
        [],
        I
    ),
    %% Bot tokens are "<bot id>:<secret>"; ":" is legal in a path segment, so it
    %% stays literal and a valid token is unchanged, while "/", "?" or "#"
    %% cannot retarget the request.
    Token = thinwrap_notifications_util:quote(
        thinwrap_notifications_input:secret(Config, bot_token), <<":">>
    ),
    Url = <<"https://api.telegram.org/bot", Token/binary, "/sendMessage">>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Url, Body, Headers, Query),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse
        thinwrap_notifications_error:fail(build_error(Status, Raw, RH)),
    %% Soft-rejection path: HTTP 200 with `ok: false`. Telegram emits this for
    %% some validation cases; route through the same mapper using the
    %% body-supplied error_code (or 400 as a defensive fallback).
    case thinwrap_notifications_json:get(Raw, <<"ok">>) of
        true ->
            ok;
        _ ->
            thinwrap_notifications_error:fail(
                build_error(
                    soft_status(thinwrap_notifications_json:get(Raw, <<"error_code">>)), Raw, RH
                )
            )
    end,
    thinwrap_notifications_util:result(sent, message_id(Raw), Raw).

%% The body's error_code as an HTTP-like status: a non-zero number truncated
%% toward zero, 400 when absent, zero or not a number. An integer too large
%% for a float reads as absent, as in the Python sibling.
soft_status(N) when is_number(N) ->
    try float(N) of
        F when F /= 0.0 -> trunc(F);
        _ -> 400
    catch
        error:badarg -> 400
    end;
soft_status(_) ->
    400.

%% result.message_id (a JSON number) as a string, or <<>> when absent.
message_id(Raw) ->
    case thinwrap_notifications_json:get(Raw, <<"result">>) of
        #{} = R ->
            case maps:get(<<"message_id">>, R, undefined) of
                I when is_integer(I) -> integer_to_binary(I);
                F when is_float(F), F == trunc(F) -> integer_to_binary(trunc(F));
                F when is_float(F) -> float_to_binary(F, [short]);
                _ -> <<>>
            end;
        _ ->
            <<>>
    end.

build_error(Status, Raw, Headers) ->
    Description = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Raw, <<"description">>)
    ),
    Msg =
        case Description of
            <<>> -> <<"Telegram HTTP ", (integer_to_binary(Status))/binary>>;
            _ -> Description
        end,
    #{cause := Cause} =
        Err = thinwrap_notifications_error:vendor_error(
            Status, Headers, Raw, map_code(Status, Description), Msg
        ),
    %% Telegram sends no Retry-After header; the wait rides in the body as
    %% ResponseParameters.retry_after ("seconds to wait before retrying").
    case
        thinwrap_notifications_json:get(
            thinwrap_notifications_json:get(Raw, <<"parameters">>), <<"retry_after">>
        )
    of
        RA when is_integer(RA), RA >= 0, not is_map_key(<<"retryAfter">>, Cause) ->
            Err#{
                cause := Cause#{
                    <<"retryAfter">> => integer_to_binary(RA), <<"retryAfterSeconds">> => RA
                }
            };
        _ ->
            Err
    end.

%% The Bot API server (tdlib/telegram-bot-api) answers a bad token with 401
%% "Unauthorized" and a malformed /bot<token>/ path with 404; sendMessage is a
%% fixed method, so a 404 here means the token.
map_code(S, _) when S =:= 401; S =:= 404 -> auth_failed;
%% Every 403 is chat-scoped: "bot was blocked by the user", "user is
%% deactivated", "bot was kicked from the group chat", "bot is not a member".
map_code(403, _) ->
    invalid_recipient;
map_code(429, _) ->
    rate_limited;
map_code(400, Description) ->
    case
        re:run(
            string:lowercase(Description),
            "chat not found|user_id_invalid|peer_id_invalid|chat_id_invalid",
            [unicode, {capture, none}]
        )
    of
        match -> invalid_recipient;
        nomatch -> invalid_request
    end;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(_, _) ->
    unknown.
