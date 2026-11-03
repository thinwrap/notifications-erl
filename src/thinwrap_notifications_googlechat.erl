-module(thinwrap_notifications_googlechat).
-moduledoc false.

%% Google Chat chat connector (incoming webhook). The input `to` is ignored —
%% the webhook URL targets the space directly.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{body := Text} = I) ->
    Url = thinwrap_notifications_input:secret(Config, webhook_url),
    Url =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Google Chat requires `webhookUrl` in config (webhook-URL-as-auth).">>
            )
        ),
    thinwrap_notifications_error:assert_webhook_https(Url, <<"Google Chat">>),
    %% Google Chat uses camelCase wire keys, so passthrough.body is forwarded
    %% verbatim (no casing transform). Expected keys: "cardsV2", "thread"
    %% ({name}), "fallbackText". The webhook's ?key=&token= credential query
    %% params ride in the config URL and are preserved; passthrough query is
    %% appended.
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        #{<<"text">> => Text},
        #{<<"Content-Type">> => <<"application/json; charset=UTF-8">>},
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Url, Body, Headers, Query),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    %% Google Chat returns a full JSON Message resource on success; the id is
    %% the resource name "spaces/<space-id>/messages/<message-id>".
    thinwrap_notifications_util:result(
        sent, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"name">>)), Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg =
        case
            thinwrap_notifications_json:str(
                thinwrap_notifications_json:path(Raw, [<<"error">>, <<"message">>])
            )
        of
            <<>> -> <<"Google Chat HTTP ", (integer_to_binary(Status))/binary>>;
            M -> M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

%% 401/403/404 all map to auth_failed — an invalid key, revoked webhook, or
%% deleted webhook/space are all credential failures.
map_code(S) when S =:= 401; S =:= 403; S =:= 404 -> auth_failed;
map_code(429) -> rate_limited;
map_code(400) -> invalid_request;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(_) -> unknown.
