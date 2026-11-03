-module(thinwrap_notifications_pusherbeams).
-moduledoc false.

%% Pusher Beams push connector.
%%
%% Beams is the canonical outlier: the publisher must send parallel fcm / apns
%% / web platform payloads in one request, synthesized here from the baseline
%% input. Sub-baseline fields flow through the passthrough body verbatim.
%%
%% Routing precedence: a passthrough body "interests" key switches the
%% endpoint to /publishes/interests; otherwise /publishes/users. The default
%% body sets users: [to] unless the caller supplies "interests" or "users".

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    InstanceId = thinwrap_notifications_util:cfg(Config, instance_id),
    %% The instance id is interpolated into both the host and the path, so it
    %% must be one DNS label. Beams ids look like UUIDs, but the SDKs do not
    %% enforce that.
    case
        re:run(InstanceId, "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z", [{capture, none}])
    of
        match ->
            ok;
        nomatch ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:invalid_request(
                    <<
                        "Pusher Beams instance_id must be a single DNS label "
                        "(letters, digits, '-')."
                    >>
                )
            )
    end,
    Key = thinwrap_notifications_input:secret(Config, secret_key),
    %% The passthrough query is not forwarded.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        synthesize(I),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Key/binary>>
        },
        [],
        I
    ),
    Suffix =
        case passthrough_has(I, <<"interests">>) of
            true -> <<"interests">>;
            false -> <<"users">>
        end,
    Endpoint =
        <<"https://", InstanceId/binary, ".pushnotifications.pusher.com/publish_api/v1/instances/",
            InstanceId/binary, "/publishes/", Suffix/binary>>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"publishId">>)),
        Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg =
        case
            thinwrap_notifications_json:str(
                thinwrap_notifications_json:get(Raw, <<"error">>)
            )
        of
            <<>> -> <<"Pusher Beams ", (integer_to_binary(Status))/binary>>;
            M -> M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

synthesize(I) ->
    Notification = thinwrap_notifications_util:put_nonempty(
        <<"body">>,
        maps:get(body, I),
        thinwrap_notifications_util:put_nonempty(<<"title">>, maps:get(title, I), #{})
    ),
    Data = maps:get(data, I),
    %% An empty notification/alert is omitted rather than sent as {}: a
    %% data-only send is a silent push on every platform.
    Platform = thinwrap_notifications_util:put_nonempty(
        <<"data">>,
        Data,
        thinwrap_notifications_util:put_nonempty(<<"notification">>, Notification, #{})
    ),
    %% `apns` is Apple's payload; Beams documents custom data under apns.data.
    %% A data-only iOS push needs aps.content-available to be delivered in the
    %% background.
    Aps =
        case map_size(Notification) of
            0 -> #{<<"content-available">> => 1};
            _ -> #{<<"alert">> => Notification}
        end,
    Apns = thinwrap_notifications_util:put_nonempty(<<"data">>, Data, #{<<"aps">> => Aps}),
    Wire = thinwrap_notifications_util:put_nonempty(
        <<"web">>,
        Platform,
        thinwrap_notifications_util:put_nonempty(<<"fcm">>, Platform, #{<<"apns">> => Apns})
    ),
    %% Recipient routing (precedence: interests > users > [to]).
    case passthrough_has(I, <<"interests">>) orelse passthrough_has(I, <<"users">>) of
        true -> Wire;
        false -> Wire#{<<"users">> => [maps:get(to, I)]}
    end.

passthrough_has(I, Key) ->
    case maps:get(Key, thinwrap_notifications_passthrough:body(I), null) of
        null -> false;
        _ -> true
    end.

%% Beams Publish API error table (pusher.com/docs/beams/reference/publish-api).
%% 401 "Incorrect API Key."
map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
%% 400 bad content type / body; 404 "Could not find the instance."; 422 "JSON
%% does not our match schema." — the request is wrong, not the recipient.
map_code(S) when S =:= 400; S =:= 404; S =:= 422 -> invalid_request;
%% 402 "Publishing has been blocked due to being over plan limits." — a quota,
%% like SparkPost's 420 sending limit.
map_code(S) when S =:= 402; S =:= 429 -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(_) -> unknown.
