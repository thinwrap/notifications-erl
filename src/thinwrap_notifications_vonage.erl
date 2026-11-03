-module(thinwrap_notifications_vonage).
-moduledoc false.

%% Vonage (Nexmo) SMS connector (form POST, form-field auth, kebab-case).
%%
%% Vonage emits HTTP 200 even for soft errors — messages[0].status is the
%% source of truth; a non-"0" status is mapped via ?STATUS_TO_CODE.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://rest.nexmo.com/sms/json">>).

%% Vonage's per-message soft-error status codes. Status "0" is success and
%% never routes here; unmapped statuses fall back to unknown.
-define(STATUS_TO_CODE, #{
    %% Throttled
    <<"1">> => rate_limited,
    %% Missing params
    <<"2">> => invalid_request,
    %% Invalid params
    <<"3">> => invalid_request,
    %% Invalid credentials
    <<"4">> => auth_failed,
    %% Internal error
    <<"5">> => provider_unavailable,
    %% Invalid message
    <<"6">> => invalid_request,
    %% Number barred
    <<"7">> => invalid_recipient,
    %% Partner account barred
    <<"8">> => auth_failed,
    %% Partner quota exceeded
    <<"9">> => auth_failed,
    %% Account not enabled for REST
    <<"11">> => invalid_request,
    %% Message too long
    <<"12">> => invalid_request,
    %% Communication failed
    <<"13">> => invalid_request,
    %% Invalid signature
    <<"14">> => invalid_request,
    %% Invalid sender address (from)
    <<"15">> => invalid_request,
    %% Invalid TTL
    <<"16">> => invalid_request,
    %% Facility not allowed
    <<"19">> => invalid_request,
    %% Invalid message class
    <<"20">> => invalid_request,
    %% Bad callback :: missing protocol
    <<"23">> => invalid_request,
    %% Non-Whitelisted Destination
    <<"29">> => invalid_recipient,
    %% Invalid Phone Number
    <<"34">> => invalid_recipient
}).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    From =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Vonage requires `from` in either the input or the config.">>
            )
        ),
    %% Passthrough keys are sent exactly as given: write Vonage's own
    %% kebab-case names (client-ref, status-report-req).
    Fields = thinwrap_notifications_passthrough:merge_form(
        [
            {<<"api_key">>, thinwrap_notifications_input:secret(Config, api_key)},
            {<<"api_secret">>, thinwrap_notifications_input:secret(Config, api_secret)},
            {<<"from">>, From},
            {<<"to">>, maps:get(to, I)},
            {<<"text">>, maps:get(body, I)}
        ],
        I
    ),
    {_, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{}, #{<<"Content-Type">> => <<"application/x-www-form-urlencoded">>}, [], I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_form(Config, ?ENDPOINT, Fields, Headers, []),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, RB),
    Raw = thinwrap_notifications_json:decode(RB),
    Message =
        case
            thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"messages">>))
        of
            [M | _] ->
                M;
            _ ->
                thinwrap_notifications_error:fail(
                    thinwrap_notifications_error:vendor_error(
                        Status, RH, Raw, unknown, <<"Vonage response missing `messages[0]`.">>
                    )
                )
        end,
    case thinwrap_notifications_json:str(thinwrap_notifications_json:get(Message, <<"status">>)) of
        <<"0">> ->
            thinwrap_notifications_util:result(
                sent,
                thinwrap_notifications_json:str(
                    thinwrap_notifications_json:get(Message, <<"message-id">>)
                ),
                Raw
            );
        S ->
            ErrText = thinwrap_notifications_util:first_non_empty([
                thinwrap_notifications_json:str(
                    thinwrap_notifications_json:get(Message, <<"error-text">>)
                ),
                <<"Vonage status ", S/binary>>
            ]),
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:vendor_error(Status, RH, Raw, status_code(S), ErrText)
            )
    end.

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), binary()) -> no_return().
fail_response(Status, RH, RB) ->
    %% A non-2xx body is not the messages envelope; it rides as text.
    Msg =
        case RB of
            <<>> -> <<"Vonage HTTP ", (integer_to_binary(Status))/binary>>;
            _ -> RB
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, RB, map_code(Status), Msg)
    ).

status_code(S) -> maps:get(S, ?STATUS_TO_CODE, unknown).

%% The HTTP-layer (non-2xx) classifier.
map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
