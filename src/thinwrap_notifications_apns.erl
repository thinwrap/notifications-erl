-module(thinwrap_notifications_apns).
-moduledoc false.

%% Apple Push Notification service (APNs) push connector, token-based (.p8)
%% auth.
%%
%% Auth flow: resolve an ES256 JWT (from the caller's token_cache when supplied
%% and unexpired, else sign fresh), then POST to
%% https://api.push.apple.com/3/device/<token> (or the sandbox host) with
%% authorization: bearer <jwt> and apns-topic headers.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% Cache lifetime handed to the token_cache. Apple's documented max JWT
%% validity is ~60 minutes; a 50-minute TTL leaves a 10-minute safety margin.
-define(JWT_CACHE_TTL, 50 * 60).
%% Apple: the `alert` push type is "for notifications that trigger a user
%% interaction—for example, an alert, badge, or sound".
-define(USER_FACING_APS_KEYS, [<<"alert">>, <<"badge">>, <<"sound">>]).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    %% APNs mandates HTTP/2. The default transport (OTP httpc) is HTTP/1.1-only,
    %% so with it a push cannot succeed — fail fast instead of a confusing
    %% mid-request error. A caller-injected transport may be HTTP/2-capable, so
    %% that case is NOT blocked.
    case maps:get(transport, Config) of
        {thinwrap_notifications_httpc, _} ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:new(invalid_request, #{
                    message =>
                        <<"APNs requires HTTP/2, but no HTTP/2-capable transport was provided">>,
                    provider_message =>
                        <<
                            "APNs requires HTTP/2. The default transport (OTP httpc) speaks only "
                            "HTTP/1.1, so pushes would fail. Inject an HTTP/2-capable transport "
                            "with the config's transport key."
                        >>
                })
            );
        _ ->
            ok
    end,
    Env = thinwrap_notifications_util:cfg(Config, env),
    %% A typo such as "prod" must not silently pick the sandbox: production
    %% device tokens then fail there as BadDeviceToken (invalid_recipient) and
    %% a caller would purge valid tokens.
    lists:member(Env, [<<>>, <<"sandbox">>, <<"production">>]) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"APNs config env must be 'production' or 'sandbox' (empty means sandbox).">>
            )
        ),
    Jwt = jwt(Config),
    %% APNs is HTTP/2 POST to /3/device/{token} — headers + JSON body only, no
    %% query params, so the passthrough query is not forwarded.
    {Body0, Headers0, _} = thinwrap_notifications_passthrough:merge(
        build_body(I),
        #{
            <<"authorization">> => <<"bearer ", Jwt/binary>>,
            <<"apns-topic">> => thinwrap_notifications_util:cfg(Config, bundle_id)
        },
        [],
        I
    ),
    {Body, Headers} = apply_push_type(Body0, Headers0),
    Host =
        case Env of
            <<"production">> -> <<"api.push.apple.com">>;
            _ -> <<"api.sandbox.push.apple.com">>
        end,
    Endpoint =
        <<"https://", Host/binary, "/3/device/",
            (thinwrap_notifications_util:quote(maps:get(to, I), <<>>))/binary>>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, []),
    thinwrap_notifications_util:ok_status(Status) orelse
        error_response(Status, RH, thinwrap_notifications_json:decode(RB)),
    %% APNs returns an empty body on 200; the message id is the apns-id header.
    thinwrap_notifications_util:result(sent, maps:get(<<"apns-id">>, RH, <<>>), #{}).

%% Resolve the ES256 JWT via the caller's token_cache when configured (key
%% "apns:" ++ team_id ++ ":" ++ key_id ++ ":" ++ bundle_id), else sign fresh.
jwt(Config) ->
    TeamId = thinwrap_notifications_util:cfg(Config, team_id),
    KeyId = thinwrap_notifications_util:cfg(Config, key_id),
    Key =
        <<"apns:", TeamId/binary, ":", KeyId/binary, ":",
            (thinwrap_notifications_util:cfg(Config, bundle_id))/binary>>,
    case thinwrap_notifications_token_cache:lookup(Config, Key) of
        {ok, Token} ->
            Token;
        miss ->
            Header = [{<<"alg">>, <<"ES256">>}, {<<"kid">>, KeyId}, {<<"typ">>, <<"JWT">>}],
            Claims = [{<<"iss">>, TeamId}, {<<"iat">>, erlang:system_time(second)}],
            Pem = thinwrap_notifications_input:secret(Config, private_key),
            %% The signer never raises: only the failure kind comes back, never
            %% the crypto exception (its reason can hold the private-key bytes).
            case thinwrap_notifications_crypto:sign_es256_jwt(Header, Claims, Pem) of
                {ok, Token} ->
                    ok = thinwrap_notifications_token_cache:store(
                        Config,
                        Key,
                        Token,
                        thinwrap_notifications_token_cache:now_seconds() + ?JWT_CACHE_TTL
                    ),
                    Token;
                {error, Kind} ->
                    Desc = <<"APNs JWT signing failed (", Kind/binary, ")">>,
                    thinwrap_notifications_error:fail(
                        thinwrap_notifications_error:new(auth_failed, #{
                            message => Desc,
                            provider_message => Desc,
                            cause => #{<<"raw">> => #{<<"exception">> => Kind}}
                        })
                    )
            end
    end.

build_body(I) ->
    Alert = thinwrap_notifications_util:put_nonempty(
        <<"body">>,
        maps:get(body, I),
        thinwrap_notifications_util:put_nonempty(<<"title">>, maps:get(title, I), #{})
    ),
    Aps = thinwrap_notifications_util:put_nonempty(<<"alert">>, Alert, #{}),
    %% APNs spec: custom data keys merge at the root of the payload, alongside
    %% aps. The reserved "aps" key is skipped so data can never clobber the
    %% constructed alert/badge/sound dictionary (use passthrough to shape aps).
    maps:merge(maps:remove(<<"aps">>, maps:get(data, I)), #{<<"aps">> => Aps}).

%% Derive apns-push-type from the MERGED payload: `alert` when aps carries an
%% alert, badge or sound (a badge of 0 clears the badge, so presence counts,
%% not truthiness), else `background`. A caller-set header wins, and the
%% background extras follow the effective type.
%%
%% For a background push Apple says "Always use priority 5. Using priority 10
%% is an error" (and an omitted apns-priority means 10), and the aps
%% dictionary "includes only the content-available key".
apply_push_type(Body, Headers0) ->
    Aps0 =
        case maps:get(<<"aps">>, Body, undefined) of
            #{} = A -> A;
            _ -> #{}
        end,
    {PushType, Headers1} =
        case header(Headers0, <<"apns-push-type">>) of
            undefined ->
                UserFacing = lists:any(
                    fun(K) -> not lists:member(maps:get(K, Aps0, null), [null, undefined]) end,
                    ?USER_FACING_APS_KEYS
                ),
                T =
                    case UserFacing of
                        true -> <<"alert">>;
                        false -> <<"background">>
                    end,
                {T, Headers0#{<<"apns-push-type">> => T}};
            T ->
                {T, Headers0}
        end,
    case is_background(PushType) of
        true ->
            Aps = maps:merge(#{<<"content-available">> => 1}, Aps0),
            Headers =
                case header(Headers1, <<"apns-priority">>) of
                    undefined -> Headers1#{<<"apns-priority">> => <<"5">>};
                    _ -> Headers1
                end,
            {Body#{<<"aps">> => Aps}, Headers};
        false ->
            {Body#{<<"aps">> => Aps0}, Headers1}
    end.

is_background(T) when is_binary(T) ->
    string:lowercase(string:trim(T)) =:= <<"background">>;
is_background(_) ->
    false.

%% Case-insensitive header lookup (passthrough may spell names any way).
header(Headers, Lower) ->
    case
        [
            V
         || K := V <- Headers,
            string:lowercase(thinwrap_notifications_util:bin(K)) =:= Lower
        ]
    of
        [V | _] -> V;
        [] -> undefined
    end.

-spec error_response(integer(), map(), term()) -> no_return().
error_response(Status, RH, Raw) ->
    Reason = thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"reason">>)),
    Msg =
        case {Status, Reason} of
            {429, <<"TooManyProviderTokenUpdates">>} ->
                <<
                    "TooManyProviderTokenUpdates: APNs allows one new provider token per "
                    "20 minutes; supply the config's token_cache so sends reuse the token"
                >>;
            {_, <<>>} ->
                <<"APNs HTTP ", (integer_to_binary(Status))/binary>>;
            _ ->
                Reason
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status, Reason), Msg)
    ).

map_code(400, <<"BadDeviceToken">>) ->
    invalid_recipient;
map_code(400, _) ->
    invalid_request;
map_code(403, <<"BadDeviceToken">>) ->
    invalid_recipient;
%% InvalidProviderToken / MissingProviderToken / ExpiredProviderToken and any
%% other 403 all classify as auth_failed.
map_code(403, _) ->
    auth_failed;
map_code(410, _) ->
    invalid_recipient;
map_code(413, _) ->
    invalid_request;
%% Minting a new JWT per send (no token_cache) trips this, and every retry
%% re-trips it, so it is a configuration error, not a back-off.
map_code(429, <<"TooManyProviderTokenUpdates">>) ->
    auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(_, _) ->
    unknown.
