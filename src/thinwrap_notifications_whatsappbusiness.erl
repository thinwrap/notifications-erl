-module(thinwrap_notifications_whatsappbusiness).
-moduledoc false.

%% WhatsApp Business (Meta Cloud API) chat connector.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(DEFAULT_GRAPH_API_VERSION, <<"v21.0">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, #{body := Text, to := To} = I) ->
    To =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"WhatsApp Business requires `to` (E.164 phone number).">>
            )
        ),
    Token = thinwrap_notifications_input:secret(Config, access_token),
    %% Passthrough keys are sent exactly as given: write the Cloud API's own
    %% snake_case names (recipient_type, template, …).
    {Body, Headers, Query} = thinwrap_notifications_passthrough:merge(
        #{
            <<"messaging_product">> => <<"whatsapp">>,
            <<"recipient_type">> => <<"individual">>,
            <<"to">> => To,
            <<"type">> => <<"text">>,
            <<"text">> => #{<<"body">> => Text}
        },
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", Token/binary>>
        },
        [],
        I
    ),
    Version = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_util:cfg(Config, graph_api_version), ?DEFAULT_GRAPH_API_VERSION
    ]),
    %% Escaped as path segments so a stray "/" or "?" cannot retarget the request.
    Endpoint =
        <<"https://graph.facebook.com/", (thinwrap_notifications_util:quote(Version, <<>>))/binary,
            "/",
            (thinwrap_notifications_util:quote(
                thinwrap_notifications_util:cfg(Config, phone_number_id), <<>>
            ))/binary,
            "/messages">>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, Query),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse
        thinwrap_notifications_error:fail(build_error(Status, RH, Raw)),
    thinwrap_notifications_util:result(sent, message_id(Raw), Raw).

build_error(Status, RH, Raw) ->
    ErrObj = thinwrap_notifications_json:get(Raw, <<"error">>),
    Msg =
        case
            thinwrap_notifications_json:str(thinwrap_notifications_json:get(ErrObj, <<"message">>))
        of
            <<>> -> <<"WhatsApp HTTP ", (integer_to_binary(Status))/binary>>;
            M -> M
        end,
    Code = error_code(thinwrap_notifications_json:get(ErrObj, <<"code">>)),
    thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status, Code), Msg).

%% Code 0 is a real Cloud API code (an authentication failure), so an absent
%% code must stay distinguishable from it. A float truncates toward zero; an
%% integer a float cannot hold exactly is no code, as in the Python sibling.
error_code(F) when is_float(F) -> trunc(F);
error_code(N) when is_integer(N) ->
    try float(N) of
        F when F == N -> N;
        _ -> undefined
    catch
        error:badarg -> undefined
    end;
error_code(_) ->
    undefined.

%% messages[0].id from a success envelope.
message_id(Raw) ->
    case thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"messages">>)) of
        [First | _] ->
            thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"id">>));
        _ ->
            <<>>
    end.

%% Port Meta's Cloud API error-code truth table. The Cloud API reuses HTTP 400
%% for auth, throttling and payload errors alike, so a known code decides
%% before the status.
map_code(Status, Code) when is_integer(Code) ->
    case code_map(Code) of
        undefined when Code >= 200, Code =< 299 -> auth_failed;
        undefined -> status_code(Status);
        Mapped -> Mapped
    end;
map_code(Status, undefined) ->
    status_code(Status).

status_code(S) when S =:= 401; S =:= 403 -> auth_failed;
status_code(429) -> rate_limited;
status_code(S) when S >= 500 -> provider_unavailable;
status_code(400) -> invalid_request;
status_code(_) -> unknown.

%% https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes
%% 0 unable to authenticate the app user, 3 capability, 10 permission not
%% granted, 190 access token expired, 131005 permission, 131031 account
%% restricted, 368 policy restriction (200-299 are handled as a range).
code_map(C) when
    C =:= 0; C =:= 3; C =:= 10; C =:= 190; C =:= 131005; C =:= 131031; C =:= 368
->
    auth_failed;
%% 4 app rate limit, 80007 WABA rate limit, 130429 Cloud API throughput,
%% 131048 spam rate limit, 131056 too many messages to the same recipient.
code_map(C) when C =:= 4; C =:= 80007; C =:= 130429; C =:= 131048; C =:= 131056 ->
    rate_limited;
%% 131026 undeliverable (not on WhatsApp / old version), 131021 sender is the
%% recipient.
code_map(C) when C =:= 131026; C =:= 131021 ->
    invalid_recipient;
%% 131008 missing required parameter, 131047 24-hour window closed (send a
%% template; the recipient is valid), 133010 the BUSINESS number is not
%% registered, plus invalid parameters, unsupported types, template errors and
%% payment (131042).
code_map(C) when
    C =:= 100;
    C =:= 131008;
    C =:= 131009;
    C =:= 131042;
    C =:= 131045;
    C =:= 131047;
    C =:= 131051;
    C =:= 132000;
    C =:= 132001;
    C =:= 132012;
    C =:= 133010
->
    invalid_request;
%% 1/2 API unavailable, 131000 unknown, 131016 service unavailable, 131057
%% account in maintenance.
code_map(C) when C =:= 1; C =:= 2; C =:= 131000; C =:= 131016; C =:= 131057 ->
    provider_unavailable;
code_map(_) ->
    undefined.
