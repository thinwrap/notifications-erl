-module(thinwrap_notifications_discord).
-moduledoc false.

%% Discord Incoming Webhook chat connector (webhook-URL-as-auth, ?wait=true).
%%
%% The webhook URL IS the credential and targets the channel directly, so the
%% input `to` is unused. `?wait=true` is always appended (overridable via
%% passthrough.query) so Discord returns the created message JSON instead of
%% an empty 204; target an existing thread by adding thread_id to
%% passthrough.query.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{body := Text} = I) ->
    Url = thinwrap_notifications_input:secret(Config, webhook_url),
    Url =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Discord requires `webhook_url` in config (webhook-URL-as-auth).">>
            )
        ),
    thinwrap_notifications_error:assert_webhook_https(Url, <<"Discord">>),
    %% Passthrough keys are sent exactly as given: write Discord's own
    %% snake_case names (avatar_url, allowed_mentions, thread_name).
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        #{<<"content">> => Text},
        #{<<"Content-Type">> => <<"application/json">>},
        [{<<"wait">>, <<"true">>}],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Url, Body, Headers, Query),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    %% With ?wait=true, success is HTTP 200 with the created message JSON. Be
    %% defensive against 204 No Content / an empty body (raw is null there).
    thinwrap_notifications_util:result(
        sent, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"id">>)), Raw
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
            <<>> -> <<"Discord HTTP ", (integer_to_binary(Status))/binary>>;
            M -> M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

%% 401/403/404 all map to auth_failed — an invalid, revoked, or deleted
%% webhook URL is a credential failure.
map_code(S) when S =:= 401; S =:= 403; S =:= 404 -> auth_failed;
map_code(429) -> rate_limited;
map_code(400) -> invalid_request;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(_) -> unknown.
