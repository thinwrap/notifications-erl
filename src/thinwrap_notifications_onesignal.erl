-module(thinwrap_notifications_onesignal).
-moduledoc false.

%% OneSignal push connector (Create notification).
%%
%% The wire body is snake_case-native and merged verbatim. OneSignal answers
%% HTTP 200 even when all recipients are invalid; the errors field is
%% inspected after the HTTP layer.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% OneSignal serves each API-key generation from a different base URL with a
%% different auth scheme: current App API Keys (prefixed "os_v2_") use
%% api.onesignal.com + "Authorization: Key", legacy REST API keys (no longer
%% creatable) use onesignal.com/api/v1 + "Authorization: Basic".
-define(ENDPOINT, <<"https://api.onesignal.com/notifications?c=push">>).
-define(LEGACY_ENDPOINT, <<"https://onesignal.com/api/v1/notifications">>).
-define(CURRENT_KEY_PREFIX, "os_v2_").

%% Case-insensitive substrings that, in OneSignal's HTTP-200 errors array,
%% classify the send as invalid_recipient.
-define(INVALID_RECIPIENT_MARKERS, [
    <<"all included players are not subscribed">>,
    <<"invalid_player_ids">>,
    <<"invalid_external_user_ids">>,
    <<"no subscriptions">>
]).

%% Targeting passthrough body keys that, when present, suppress the default
%% include_subscription_ids: [to]. OneSignal rejects mixing include_aliases or
%% segments with any other targeting parameter, so a caller-chosen target must
%% be the only one on the wire.
-define(RECIPIENT_KEYS, [
    <<"include_aliases">>,
    <<"include_subscription_ids">>,
    <<"included_segments">>,
    <<"excluded_segments">>,
    <<"filters">>,
    <<"include_player_ids">>,
    <<"include_external_user_ids">>,
    <<"include_email_tokens">>,
    <<"include_phone_numbers">>
]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    {Endpoint, Authorization} =
        case thinwrap_notifications_input:secret(Config, api_key) of
            <<?CURRENT_KEY_PREFIX, _/binary>> = Key -> {?ENDPOINT, <<"Key ", Key/binary>>};
            Key -> {?LEGACY_ENDPOINT, <<"Basic ", Key/binary>>}
        end,
    %% The passthrough query is not forwarded.
    {Body, Headers, _} = thinwrap_notifications_passthrough:merge(
        build_body(Config, I),
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Accept">> => <<"application/json">>,
            <<"Authorization">> => Authorization
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:vendor_error(
                Status, RH, Raw, map_code(Status), error_message(Raw, Status)
            )
        ),
    case thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"id">>)) of
        <<>> ->
            %% No notification was created: an `errors` list of unsubscribed or
            %% invalid targets is the reason. With an id, OneSignal created the
            %% notification and `errors` only names the targets it skipped,
            %% which stay visible in `raw`.
            thinwrap_notifications_json:get(Raw, <<"errors">>) =/= undefined andalso
                ticket_error(Raw, Status),
            Msg = <<"OneSignal returned no notification id">>,
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:new(invalid_request, #{
                    status => Status,
                    message => Msg,
                    provider_message => Msg,
                    cause => #{<<"raw">> => Raw}
                })
            );
        Id ->
            thinwrap_notifications_util:result(sent, Id, Raw)
    end.

build_body(Config, I) ->
    Base0 = #{<<"app_id">> => thinwrap_notifications_util:cfg(Config, app_id)},
    Base =
        case has_recipient(I) of
            true -> Base0;
            false -> Base0#{<<"include_subscription_ids">> => [maps:get(to, I)]}
        end,
    Title = maps:get(title, I),
    Text = maps:get(body, I),
    lists:foldl(
        fun({K, V}, Acc) -> thinwrap_notifications_util:put_nonempty(K, V, Acc) end,
        Base,
        [
            {<<"headings">>,
                case Title of
                    <<>> -> <<>>;
                    _ -> #{<<"en">> => Title}
                end},
            {<<"contents">>,
                case Text of
                    <<>> -> <<>>;
                    _ -> #{<<"en">> => Text}
                end},
            {<<"data">>, maps:get(data, I)}
        ]
    ).

has_recipient(I) ->
    Pt = thinwrap_notifications_passthrough:body(I),
    lists:any(fun(K) -> present(maps:get(K, Pt, null)) end, ?RECIPIENT_KEYS).

present(null) -> false;
present(undefined) -> false;
present(_) -> true.

%% Map an HTTP-200 errors field (string array or object map) to an
%% invalid_recipient error; returns `false` (no-op) when no known
%% invalid-recipient marker is present.
ticket_error(Raw, HttpStatus) ->
    Errors = thinwrap_notifications_json:get(Raw, <<"errors">>),
    {Invalid, First} =
        case Errors of
            L when is_list(L) ->
                F =
                    case L of
                        [E0 | _] -> thinwrap_notifications_json:str(E0);
                        [] -> <<>>
                    end,
                {lists:any(fun has_marker/1, L), F};
            #{} = M ->
                Has =
                    non_empty_list(maps:get(<<"invalid_external_user_ids">>, M, null)) orelse
                        non_empty_list(maps:get(<<"invalid_player_ids">>, M, null)) orelse
                        non_empty_map(maps:get(<<"invalid_aliases">>, M, null)),
                case Has of
                    true -> {true, thinwrap_notifications_util:response_text(M)};
                    false -> {false, <<>>}
                end;
            _ ->
                {false, <<>>}
        end,
    Invalid andalso fail_invalid_recipient(HttpStatus, Raw, First).

-spec fail_invalid_recipient(integer(), term(), binary()) -> no_return().
fail_invalid_recipient(HttpStatus, Raw, First) ->
    Msg =
        case First of
            <<>> -> <<"OneSignal invalid recipient">>;
            _ -> First
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:new(invalid_recipient, #{
            status => HttpStatus,
            message => Msg,
            provider_message => Msg,
            cause => #{<<"raw">> => Raw}
        })
    ).

has_marker(E) ->
    S = string:lowercase(thinwrap_notifications_json:str(E)),
    S =/= <<>> andalso
        lists:any(fun(Mk) -> binary:match(S, Mk) =/= nomatch end, ?INVALID_RECIPIENT_MARKERS).

non_empty_list([_ | _]) -> true;
non_empty_list(_) -> false.

non_empty_map(#{} = M) -> map_size(M) > 0;
non_empty_map(_) -> false.

error_message(Raw, Status) ->
    Errors = thinwrap_notifications_json:get(Raw, <<"errors">>),
    FromList =
        case Errors of
            [E | _] -> thinwrap_notifications_json:str(E);
            _ -> <<>>
        end,
    case {FromList, Errors} of
        {<<>>, #{}} ->
            thinwrap_notifications_util:response_text(Errors);
        {<<>>, _} ->
            case
                thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"message">>))
            of
                <<>> -> <<"OneSignal ", (integer_to_binary(Status))/binary>>;
                M -> M
            end;
        _ ->
            FromList
    end.

map_code(401) -> auth_failed;
map_code(400) -> invalid_request;
map_code(404) -> invalid_request;
map_code(429) -> rate_limited;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(_) -> unknown.
