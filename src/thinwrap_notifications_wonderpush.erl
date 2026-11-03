-module(thinwrap_notifications_wonderpush).
-moduledoc false.

%% WonderPush push connector (Management API /v1/deliveries).
%%
%% The wire body is camelCase-native and merged verbatim.
%%
%% Baseline mapping: to -> targetUserIds: [to]; title -> notification.alert.title;
%% body -> notification.alert.text; data -> notification.push.custom.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://management-api.wonderpush.com/v1/deliveries">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    Token = thinwrap_notifications_input:secret(Config, access_token),
    %% Unlike the other push connectors, the passthrough query IS forwarded.
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Token/binary>>
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, ?ENDPOINT, Body, Headers, Query),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    Id =
        case thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"id">>)) of
            <<>> ->
                thinwrap_notifications_json:str(
                    thinwrap_notifications_json:get(Raw, <<"notificationId">>)
                );
            V ->
                V
        end,
    thinwrap_notifications_util:result(sent, Id, Raw).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg =
        case
            thinwrap_notifications_json:str(
                thinwrap_notifications_json:path(Raw, [<<"error">>, <<"message">>])
            )
        of
            <<>> -> <<"WonderPush HTTP ", (integer_to_binary(Status))/binary>>;
            M -> M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

build_body(Config, I) ->
    %% Recipient routing: a passthrough body targetUserIds value overrides this
    %% default (the deep merge replaces the list).
    Base = thinwrap_notifications_util:put_nonempty(
        <<"applicationId">>,
        thinwrap_notifications_util:cfg(Config, application_id),
        #{<<"targetUserIds">> => [maps:get(to, I)]}
    ),
    Alert = thinwrap_notifications_util:put_nonempty(
        <<"text">>,
        maps:get(body, I),
        thinwrap_notifications_util:put_nonempty(<<"title">>, maps:get(title, I), #{})
    ),
    Push =
        case maps:get(data, I) of
            D when D =:= #{} -> #{};
            %% WonderPush delivers custom key/values from push.custom; there is
            %% no top-level notification.custom field.
            D -> #{<<"custom">> => D}
        end,
    Notification = thinwrap_notifications_util:put_nonempty(
        <<"push">>, Push, thinwrap_notifications_util:put_nonempty(<<"alert">>, Alert, #{})
    ),
    thinwrap_notifications_util:put_nonempty(<<"notification">>, Notification, Base).

map_code(401) -> auth_failed;
map_code(404) -> invalid_recipient;
map_code(429) -> rate_limited;
map_code(S) when S >= 400, S < 500 -> invalid_request;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(_) -> unknown.
