-module(thinwrap_notifications_infobip).
-moduledoc false.

%% Infobip SMS connector (v2 advanced JSON API, per-account base URL).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% base_url is the per-account host (xyz123.api.infobip.com) and is placed
%% after "https://", so anything beyond a bare DNS hostname — a scheme, path,
%% port, userinfo ("evil.com@") or trailing slash — could send the App key
%% elsewhere. Anchored with \z: "$" alone would accept a trailing newline.
-define(LABEL_RE, "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z").

%% Infobip status group 5 (REJECTED): "rejected by Infobip or the operator".
%% The send is answered 200 but the message never leaves Infobip.
-define(REJECTED_GROUP_ID, 5).
-define(REJECTED_GROUP_NAME, <<"REJECTED">>).
%% Substrings of REJECTED_* status names that point at the destination number
%% (REJECTED_DESTINATION, REJECTED_PREFIX_MISSING, MISSING_TO, REJECTED_DND,
%% REJECTED_NOT_REGISTERED, ...).
-define(INVALID_RECIPIENT_MARKERS, [
    <<"DESTINATION">>, <<"PREFIX">>, <<"MISSING_TO">>, <<"DND">>, <<"NOT_REGISTERED">>
]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    BaseUrl = thinwrap_notifications_util:cfg(Config, base_url),
    %% The value is not echoed: a mis-pasted base_url can hold a credential.
    is_hostname(BaseUrl) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<
                    "Infobip base_url must be a bare hostname such as 'xyz123.api.infobip.com' "
                    "(no scheme, path, port or trailing slash)."
                >>
            )
        ),
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    From =:= <<>> andalso
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"Infobip requires `from` in either the input or the config.">>
            )
        ),
    %% Infobip's v2 advanced endpoint takes a messages array even for one
    %% message; each message carries destinations:[{to}]. Wire keys are
    %% camelCase and passthrough keys ride as given, so no casing transform.
    Entry = #{
        <<"from">> => From,
        <<"destinations">> => [#{<<"to">> => maps:get(to, I)}],
        <<"text">> => maps:get(body, I)
    },
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{<<"messages">> => [Entry]},
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> =>
                <<"App ", (thinwrap_notifications_input:secret(Config, api_key))/binary>>,
            <<"Accept">> => <<"application/json">>
        },
        [],
        I
    ),
    Endpoint = <<"https://", BaseUrl/binary, "/sms/2/text/advanced">>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail(Status, RH, Raw),
    First =
        case
            thinwrap_notifications_json:list(thinwrap_notifications_json:get(Raw, <<"messages">>))
        of
            [M | _] -> M;
            _ -> undefined
        end,
    ok = raise_if_rejected(Status, RH, Raw, thinwrap_notifications_json:get(First, <<"status">>)),
    thinwrap_notifications_util:result(
        sent,
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(First, <<"messageId">>)),
        Raw
    ).

is_hostname(<<>>) ->
    false;
is_hostname(V) when byte_size(V) > 253 -> false;
is_hostname(V) ->
    lists:all(
        fun(Label) -> re:run(Label, ?LABEL_RE, [{capture, none}]) =:= match end,
        binary:split(V, <<".">>, [global])
    ).

%% Body shape: {requestError:{serviceException:{messageId,text}}}. The EC_*
%% messageId is preserved on cause.raw but not individually mapped — HTTP
%% status drives the canonical classification.
-spec fail(integer(), map(), term()) -> no_return().
fail(Status, RH, Raw) ->
    Se = thinwrap_notifications_json:path(Raw, [<<"requestError">>, <<"serviceException">>]),
    Code = thinwrap_notifications_json:str(thinwrap_notifications_json:get(Se, <<"messageId">>)),
    Msg =
        case thinwrap_notifications_json:str(thinwrap_notifications_json:get(Se, <<"text">>)) of
            <<>> ->
                Base = <<"Infobip HTTP ", (integer_to_binary(Status))/binary>>,
                case Code of
                    <<>> -> Base;
                    _ -> <<Base/binary, " ", Code/binary>>
                end;
            Text ->
                Text
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

raise_if_rejected(Status, RH, Raw, St) ->
    GroupId = thinwrap_notifications_json:get(St, <<"groupId">>),
    GroupName = string:uppercase(
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(St, <<"groupName">>))
    ),
    case is_number(GroupId) andalso GroupId == ?REJECTED_GROUP_ID of
        false when GroupName =/= ?REJECTED_GROUP_NAME ->
            ok;
        _ ->
            Name = string:uppercase(
                thinwrap_notifications_json:str(thinwrap_notifications_json:get(St, <<"name">>))
            ),
            Code =
                case Name of
                    <<"REJECTED_FLOODING_FILTER">> ->
                        rate_limited;
                    _ ->
                        case binary:match(Name, ?INVALID_RECIPIENT_MARKERS) of
                            nomatch -> invalid_request;
                            _ -> invalid_recipient
                        end
                end,
            Msg = thinwrap_notifications_util:first_non_empty([
                thinwrap_notifications_json:str(
                    thinwrap_notifications_json:get(St, <<"description">>)
                ),
                Name,
                <<"Infobip rejected the message">>
            ]),
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:vendor_error(Status, RH, Raw, Code, Msg)
            )
    end.

map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
