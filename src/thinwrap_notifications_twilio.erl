-module(thinwrap_notifications_twilio).
-moduledoc false.

%% Twilio SMS connector (form-encoded Messages API, Basic auth).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% Twilio REST processing regions and the edge used when none is configured.
%% Twilio retired the api.{region}.twilio.com form on 2026-04-28; a non-US
%% region now needs an edge in the host ("The edge location name (dublin,
%% sydney) is a required part of the hostname for non-US regions").
%% br1/de1/jp1/sg1/us2 are edge-only ids that process in US1, so they are not
%% regions here.
%% https://www.twilio.com/docs/global-infrastructure/edge-locations/legacy-regions
-define(REGION_DEFAULT_EDGE, #{
    <<"us1">> => <<>>,
    <<"ie1">> => <<"dublin">>,
    <<"au1">> => <<"sydney">>
}).
%% Public edge locations. The edge is interpolated into the host, so only these
%% are accepted.
-define(EDGES, [
    <<"ashburn">>,
    <<"dublin">>,
    <<"frankfurt">>,
    <<"roaming">>,
    <<"sao-paulo">>,
    <<"singapore">>,
    <<"sydney">>,
    <<"tokyo">>,
    <<"umatilla">>
]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I0) ->
    Host = resolve_host(
        thinwrap_notifications_util:cfg(Config, region),
        thinwrap_notifications_util:cfg(Config, edge)
    ),
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I0), thinwrap_notifications_util:cfg(Config, from)
    ]),
    %% Twilio's wire body is PascalCase; rewrite passthrough.body keys so
    %% camelCase keys (messagingServiceSid, mediaUrl) land in the form body.
    I = thinwrap_notifications_casing:transform_passthrough_body_top_level(I0, pascal),
    (From =/= <<>> orelse
        truthy(
            maps:get(<<"MessagingServiceSid">>, thinwrap_notifications_passthrough:body(I), null)
        )) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<
                    "Twilio requires either `from` (input or config) or a `MessagingServiceSid` "
                    "passthrough field."
                >>
            )
        ),
    Fields = thinwrap_notifications_passthrough:merge_form(
        [{<<"To">>, maps:get(to, I)}, {<<"Body">>, maps:get(body, I)}] ++
            [{<<"From">>, From} || From =/= <<>>],
        I
    ),
    AccountSid = thinwrap_notifications_util:cfg(Config, account_sid),
    {_, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{},
        #{
            <<"Authorization">> => thinwrap_notifications_util:basic_auth(
                AccountSid, thinwrap_notifications_input:secret(Config, auth_token)
            )
        },
        [],
        I
    ),
    %% Escaped as a path segment so a stray "/" or "?" cannot retarget the request.
    Endpoint =
        <<"https://", Host/binary, "/2010-04-01/Accounts/",
            (thinwrap_notifications_util:quote(AccountSid, <<>>))/binary, "/Messages.json">>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_form(Config, Endpoint, Fields, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"sid">>)), Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_json:str(
            thinwrap_notifications_json:get(Raw, <<"message">>)
        ),
        <<"Twilio HTTP error">>
    ]),
    Code = trunc(
        thinwrap_notifications_json:num(thinwrap_notifications_json:get(Raw, <<"code">>))
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Code), Msg
        )
    ).

%% `api.twilio.com` for us1 without an edge (the canonical US host), else
%% `api.{edge}.{region}.twilio.com`, the documented form the Twilio SDKs build.
resolve_host(Region0, Edge0) ->
    Region =
        case Region0 of
            <<>> -> <<"us1">>;
            _ -> Region0
        end,
    DefaultEdge =
        case maps:find(Region, ?REGION_DEFAULT_EDGE) of
            {ok, E} ->
                E;
            error ->
                thinwrap_notifications_error:fail(
                    thinwrap_notifications_error:invalid_request(
                        <<"Unknown Twilio region: ", Region/binary,
                            " (expected us1, ie1 or au1; edge-only ids such as de1 or sg1 "
                            "process in us1 — use `edge` to pick the edge location)"/utf8>>
                    )
                )
        end,
    Edge0 =:= <<>> orelse lists:member(Edge0, ?EDGES) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                iolist_to_binary([
                    "Unknown Twilio edge: ",
                    Edge0,
                    " (expected one of ",
                    lists:join(<<", ">>, ?EDGES),
                    ")"
                ])
            )
        ),
    case thinwrap_notifications_util:first_non_empty([Edge0, DefaultEdge]) of
        <<>> -> <<"api.twilio.com">>;
        Edge -> <<"api.", Edge/binary, ".", Region/binary, ".twilio.com">>
    end.

%% Python truthiness of a passthrough value.
truthy(V) -> not lists:member(V, [null, undefined, false, <<>>, [], #{}]) andalso V /= 0.

%% The Twilio (HTTP status, error code) truth table.
map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(400, C) when C =:= 21211; C =:= 21408; C =:= 21610; C =:= 21612; C =:= 21614 ->
    invalid_recipient;
map_code(400, 20003) ->
    auth_failed;
map_code(S, _) when S >= 400 -> invalid_request;
map_code(_, _) ->
    unknown.
