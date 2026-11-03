-module(thinwrap_notifications_fcm).
-moduledoc false.

%% Firebase Cloud Messaging (FCM HTTP v1) push connector.
%%
%% Auth flow: resolve an OAuth access token (from the caller's token_cache when
%% supplied and unexpired, else sign a fresh RS256 service-account JWT and
%% exchange it at Google's OAuth 2.0 endpoint), then POST {message} to the
%% project's messages:send endpoint with Authorization: Bearer <token>.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% Google's OAuth 2.0 token-exchange endpoint (also the JWT `aud`).
-define(TOKEN_ENDPOINT, <<"https://oauth2.googleapis.com/token">>).
%% OAuth scope requested for the service-account JWT.
-define(SCOPE, <<"https://www.googleapis.com/auth/firebase.messaging">>).
%% Seconds shaved off Google's reported expires_in before caching, so a token
%% near its expiry is refreshed rather than served (clock-skew / in-flight
%% margin).
-define(TOKEN_EXPIRY_SKEW_SECONDS, 60).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    AccessToken = access_token(Config),
    %% FCM's wire body is not casing-transformed; passthrough merges verbatim.
    %% The passthrough query is not forwarded.
    {Body0, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{<<"message">> => build_message(I)},
        #{
            <<"Content-Type">> => <<"application/json">>,
            <<"Authorization">> => <<"Bearer ", AccessToken/binary>>
        },
        [],
        I
    ),
    Body = single_target(Body0),
    %% Config values are escaped as path segments: a "/" or "?" in them would
    %% otherwise retarget the authenticated request.
    Endpoint =
        <<"https://fcm.googleapis.com/v1/projects/",
            (thinwrap_notifications_util:quote(
                thinwrap_notifications_util:cfg(Config, project_id), <<>>
            ))/binary,
            "/messages:send">>,
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_json(Config, Endpoint, Body, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse error_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        sent, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"name">>)), Raw
    ).

%% FCM's message target is a oneof ("At most one of the fields will be set":
%% token, fid, topic, condition). The deep merge can add a topic but cannot
%% remove the connector's token, so a passthrough target replaces it.
single_target(#{<<"message">> := #{} = M} = Body) ->
    case
        lists:any(fun(K) -> truthy(maps:get(K, M, null)) end, [
            <<"topic">>, <<"condition">>, <<"fid">>
        ])
    of
        true -> Body#{<<"message">> => maps:remove(<<"token">>, M)};
        false -> Body
    end;
single_target(Body) ->
    Body.

%% Python truthiness of a decoded JSON value.
truthy(null) -> false;
truthy(false) -> false;
truthy(<<>>) -> false;
truthy([]) -> false;
truthy(M) when M =:= #{} -> false;
truthy(N) when N == 0 -> false;
truthy(_) -> true.

build_message(I) ->
    Notification = thinwrap_notifications_util:put_nonempty(
        <<"body">>,
        maps:get(body, I),
        thinwrap_notifications_util:put_nonempty(<<"title">>, maps:get(title, I), #{})
    ),
    thinwrap_notifications_util:put_nonempty(
        <<"data">>,
        maps:get(data, I),
        thinwrap_notifications_util:put_nonempty(
            <<"notification">>,
            Notification,
            thinwrap_notifications_util:put_nonempty(<<"token">>, maps:get(to, I), #{})
        )
    ).

%% Resolve the OAuth access token via the caller's token_cache when configured
%% (key "fcm:" ++ project_id ++ ":" ++ client_email — the credential identity is
%% part of the key so a rotated service account does not serve a stale token),
%% else mint fresh.
access_token(Config) ->
    Key =
        <<"fcm:", (thinwrap_notifications_util:cfg(Config, project_id))/binary, ":",
            (thinwrap_notifications_util:cfg(Config, client_email))/binary>>,
    case thinwrap_notifications_token_cache:lookup(Config, Key) of
        {ok, Token} ->
            Token;
        miss ->
            {Token, ExpiresIn} = exchange_token(Config),
            %% Cache Google's reported expires_in minus a small skew margin.
            Ttl = max(0.0, ExpiresIn - ?TOKEN_EXPIRY_SKEW_SECONDS),
            ok = thinwrap_notifications_token_cache:store(
                Config, Key, Token, thinwrap_notifications_token_cache:now_seconds() + Ttl
            ),
            Token
    end.

%% Sign a fresh RS256 service-account JWT and exchange it for an access token
%% at Google's OAuth 2.0 endpoint.
exchange_token(Config) ->
    Jwt = sign_jwt(Config),
    Form = [
        {<<"grant_type">>, <<"urn:ietf:params:oauth:grant-type:jwt-bearer">>},
        {<<"assertion">>, Jwt}
    ],
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_form(Config, ?TOKEN_ENDPOINT, Form, #{}, []),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, RB),
    Parsed = thinwrap_notifications_json:decode(RB),
    %% A 200 with a token-less body must NOT be returned (and then CACHED) as an
    %% empty Bearer — surface a typed auth_failed instead.
    case
        thinwrap_notifications_json:str(thinwrap_notifications_json:get(Parsed, <<"access_token">>))
    of
        <<>> ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:vendor_error(
                    Status,
                    RH,
                    Parsed,
                    auth_failed,
                    <<"FCM OAuth token exchange returned a 200 with no usable access_token">>
                )
            );
        Token ->
            {Token,
                thinwrap_notifications_json:num(
                    thinwrap_notifications_json:get(Parsed, <<"expires_in">>)
                )}
    end.

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), binary()) -> no_return().
fail_response(Status, RH, RB) ->
    Msg0 = <<"FCM OAuth token exchange failed: ", (integer_to_binary(Status))/binary>>,
    Msg =
        case RB of
            <<>> -> Msg0;
            _ -> <<Msg0/binary, " ", (utf8_replace(RB))/binary>>
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, thinwrap_notifications_json:decode(RB), map_oauth_code(Status), Msg
        )
    ).

sign_jwt(Config) ->
    Pem = thinwrap_notifications_input:secret(Config, private_key),
    Now = erlang:system_time(second),
    Header = [{<<"alg">>, <<"RS256">>}, {<<"typ">>, <<"JWT">>}],
    Claims = [
        {<<"iss">>, thinwrap_notifications_util:cfg(Config, client_email)},
        {<<"scope">>, ?SCOPE},
        {<<"aud">>, ?TOKEN_ENDPOINT},
        {<<"iat">>, Now},
        {<<"exp">>, Now + 3600}
    ],
    %% The signer never raises: only the failure kind comes back, never the
    %% crypto exception (its reason can hold the private-key bytes).
    case thinwrap_notifications_crypto:sign_rs256_jwt(Header, Claims, Pem) of
        {ok, Jwt} ->
            Jwt;
        {error, Kind} ->
            Desc = <<"FCM JWT signing failed (", Kind/binary, ")">>,
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:new(auth_failed, #{
                    message => Desc,
                    provider_message => Desc,
                    cause => #{<<"raw">> => #{<<"exception">> => Kind}}
                })
            )
    end.

%% The response body as text, invalid UTF-8 bytes replaced by U+FFFD (Python's
%% `decode("utf-8", "replace")`).
%% One U+FFFD per maximal ill-formed subpart, as Python (and the Unicode
%% standard's recommended practice) does.
utf8_replace(B) ->
    case unicode:characters_to_binary(B) of
        Ok when is_binary(Ok) ->
            Ok;
        {_, Good, <<Lead, Rest/binary>>} ->
            <<Good/binary, 16#FFFD/utf8, (utf8_replace(skip_subpart(Lead, Rest)))/binary>>
    end.

%% Drop the continuation bytes that still formed a valid prefix after `Lead`.
skip_subpart(Lead, Rest) ->
    {Need, Lo, Hi} =
        case Lead of
            _ when Lead >= 16#C2, Lead =< 16#DF -> {1, 16#80, 16#BF};
            16#E0 -> {2, 16#A0, 16#BF};
            16#ED -> {2, 16#80, 16#9F};
            _ when Lead >= 16#E1, Lead =< 16#EF -> {2, 16#80, 16#BF};
            16#F0 -> {3, 16#90, 16#BF};
            16#F4 -> {3, 16#80, 16#8F};
            _ when Lead >= 16#F1, Lead =< 16#F3 -> {3, 16#80, 16#BF};
            _ -> {0, 0, 0}
        end,
    case Rest of
        <<C, More/binary>> when Need > 0, C >= Lo, C =< Hi -> skip_cont(Need - 1, More);
        _ -> Rest
    end.

skip_cont(N, <<C, More/binary>>) when N > 0, C >= 16#80, C =< 16#BF -> skip_cont(N - 1, More);
skip_cont(_, Rest) -> Rest.

-spec error_response(integer(), map(), term()) -> no_return().
error_response(Status, RH, Raw) ->
    Err = thinwrap_notifications_json:get(Raw, <<"error">>),
    FcmStatus = thinwrap_notifications_json:str(thinwrap_notifications_json:get(Err, <<"status">>)),
    Msg =
        case thinwrap_notifications_json:str(thinwrap_notifications_json:get(Err, <<"message">>)) of
            <<>> -> <<"FCM HTTP ", (integer_to_binary(Status))/binary>>;
            M -> M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status, FcmStatus), Msg)
    ).

%% Google's token endpoint answers a bad assertion or key with 400/401
%% (invalid_grant, invalid_client) — a credential problem — but a 429 or 5xx is
%% the endpoint's own state and is retryable.
map_oauth_code(429) -> rate_limited;
map_oauth_code(S) when S >= 500 -> provider_unavailable;
map_oauth_code(_) -> auth_failed.

map_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_code(404, _) -> invalid_recipient;
map_code(429, _) -> rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(400, _) -> invalid_request;
%% Fallback: the vendor error.status string disambiguates a non-canonical HTTP
%% status.
map_code(_, St) when St =:= <<"UNAUTHENTICATED">>; St =:= <<"SENDER_ID_MISMATCH">> -> auth_failed;
map_code(_, <<"INVALID_ARGUMENT">>) -> invalid_request;
map_code(_, <<"NOT_FOUND">>) -> invalid_recipient;
map_code(_, St) when St =:= <<"QUOTA_EXCEEDED">>; St =:= <<"RESOURCE_EXHAUSTED">> -> rate_limited;
map_code(_, St) when St =:= <<"UNAVAILABLE">>; St =:= <<"INTERNAL">> -> provider_unavailable;
map_code(_, _) -> unknown.
