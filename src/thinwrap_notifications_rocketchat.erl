-module(thinwrap_notifications_rocketchat).
-moduledoc false.

%% Rocket.Chat chat connector (Incoming Webhook, Slack-compatible).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{body := Text, to := To} = I) ->
    Url = thinwrap_notifications_input:secret(Config, webhook_url),
    Url =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Rocket.Chat requires `webhookUrl` in config (webhook-URL-as-auth).">>
            )
        ),
    %% The URL carries the integration token; enforced here, not only in the
    %% default transport, because an injected transport may accept http://.
    thinwrap_notifications_error:assert_webhook_https(Url, <<"Rocket.Chat">>),
    %% `to`, when set, overrides the webhook's default channel via the wire
    %% "channel" field. Rich content flows through passthrough.body verbatim
    %% (Rocket.Chat wire shape, including snake_case attachment keys like
    %% author_name / image_url / thumb_url). Expected keys: "attachments",
    %% "alias", "avatar", "emoji", "tmid", "tshow". The passthrough query is
    %% not forwarded.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        thinwrap_notifications_util:put_nonempty(<<"channel">>, To, #{<<"text">> => Text}),
        #{<<"Content-Type">> => <<"application/json">>},
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Url, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    %% Rocket.Chat Incoming Webhooks return {success:true} JSON with no message
    %% id, so provider_message_id is always empty. A non-JSON success body
    %% normalizes to an empty object (sibling parity).
    thinwrap_notifications_util:result(
        sent,
        <<>>,
        case Raw of
            null -> #{};
            _ -> Raw
        end
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"error">>)),
        thinwrap_notifications_json:str(
            thinwrap_notifications_json:get(Raw, <<"message">>)
        ),
        <<"Rocket.Chat HTTP ", (integer_to_binary(Status))/binary>>
    ]),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

%% 401/403/404 all map to auth_failed — invalid, disabled, or deleted Incoming
%% Webhook URLs are all credential failures.
map_code(S) when S =:= 401; S =:= 403; S =:= 404 -> auth_failed;
map_code(429) -> rate_limited;
map_code(400) -> invalid_request;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(_) -> unknown.
