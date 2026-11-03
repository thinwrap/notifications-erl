-module(thinwrap_notifications_sinch).
-moduledoc false.

%% Sinch SMS connector (JSON batches API, Bearer auth, snake_case).
%%
%% Region-clustered: the base URL is https://<region>.sms.api.sinch.com/...
%% with the Service Plan ID as a path parameter.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% https://developers.sinch.com/docs/sms/api-reference/ — the SMS API's
%% regional hosts. The region is interpolated into the host, so it is a
%% closed set.
-define(REGIONS, [<<"us">>, <<"eu">>, <<"au">>, <<"br">>, <<"ca">>]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    From =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Sinch requires `from` in either the input or the config.">>
            )
        ),
    Region = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_util:cfg(Config, region), <<"us">>
    ]),
    lists:member(Region, ?REGIONS) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                iolist_to_binary([
                    "Unknown Sinch region: ",
                    Region,
                    " (expected one of ",
                    lists:join(<<", ">>, ?REGIONS),
                    ")"
                ])
            )
        ),
    %% Passthrough keys are sent exactly as given: write Sinch's own snake_case
    %% names (delivery_report, callback_url, parameters, …). The batches API
    %% expects `to` as an array even for single-recipient sends.
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        #{<<"from">> => From, <<"to">> => [maps:get(to, I)], <<"body">> => maps:get(body, I)},
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> =>
                <<"Bearer ", (thinwrap_notifications_input:secret(Config, api_token))/binary>>
        },
        [],
        I
    ),
    %% Escaped as a path segment so a stray "/" or "?" cannot retarget the request.
    Endpoint =
        <<"https://", Region/binary, ".sms.api.sinch.com/xms/v1/",
            (thinwrap_notifications_util:quote(
                thinwrap_notifications_util:cfg(Config, service_plan_id), <<>>
            ))/binary,
            "/batches">>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, Query),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"id">>)), Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"text">>)),
        <<"Sinch HTTP ", (integer_to_binary(Status))/binary>>
    ]),
    Code = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Raw, <<"code">>)
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Code), Msg
        )
    ).

map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(_, C) when C =:= <<"invalid_destination">>; C =:= <<"invalid_recipient">> ->
    invalid_recipient;
map_code(S, _) when S >= 400 -> invalid_request;
map_code(_, _) ->
    unknown.
