-module(thinwrap_notifications_crypto).
-moduledoc false.

%% JWT signing for FCM (RS256) and APNs (ES256) on OTP `public_key`/`crypto`
%% (the Python sibling's `_crypto.py`). These sign the caller's own JWT with
%% the caller's own key.
%%
%% Neither function ever raises: a key that fails to parse or sign becomes
%% `{error, Kind}`, where `Kind` is only the leading atom of the failure. The
%% raw reason and stacktrace can hold the private-key bytes (public_key's
%% ASN.1 errors embed the DER being decoded), which a crash report or error
%% tracker would capture, so they never leave this module.

-include_lib("public_key/include/public_key.hrl").

-export([sign_rs256_jwt/3, sign_es256_jwt/3]).
-export_type([pairs/0]).

-type pairs() :: [{binary(), binary() | integer()}].

-doc false.
%% `Header`/`Claims` are ordered pairs, so they serialize in the siblings' key
%% order.
-spec sign_rs256_jwt(pairs(), pairs(), binary()) -> {ok, binary()} | {error, binary()}.
sign_rs256_jwt(Header, Claims, Pem) ->
    guarded(fun() ->
        Key =
            case private_key(Pem, 'RSAPrivateKey') of
                #'RSAPrivateKey'{} = K -> K;
                _ -> erlang:error(expected_rsa_key)
            end,
        SigningInput = signing_input(Header, Claims),
        %% RSASSA-PKCS1-v1_5 over SHA-256 (public_key's default RSA padding).
        Sig = public_key:sign(SigningInput, sha256, Key),
        <<SigningInput/binary, ".", (b64url(Sig))/binary>>
    end).

-doc false.
%% The signature is the IEEE P1363 raw r||s form (64 bytes) — what APNs and the
%% JWT ES256 spec require — NOT the ASN.1 DER that `public_key:sign/3` returns.
-spec sign_es256_jwt(pairs(), pairs(), binary()) -> {ok, binary()} | {error, binary()}.
sign_es256_jwt(Header, Claims, Pem) ->
    guarded(fun() ->
        Key =
            case private_key(Pem, 'ECPrivateKey') of
                #'ECPrivateKey'{parameters = {namedCurve, ?'secp256r1'}} = K -> K;
                _ -> erlang:error(expected_p256_ec_key)
            end,
        SigningInput = signing_input(Header, Claims),
        Der = public_key:sign(SigningInput, sha256, Key),
        #'ECDSA-Sig-Value'{r = R, s = S} = public_key:der_decode('ECDSA-Sig-Value', Der),
        <<SigningInput/binary, ".", (b64url(<<R:256, S:256>>))/binary>>
    end).

%% Run `F`; any failure becomes `{error, Kind}` built OUTSIDE the catch from
%% the reason's leading atom only.
guarded(F) ->
    Result =
        try
            {ok, F()}
        catch
            _:Reason -> {error, kind(Reason)}
        end,
    case Result of
        {ok, Jwt} when is_binary(Jwt) -> {ok, Jwt};
        {error, K} -> {error, K}
    end.

kind(R) when is_atom(R) -> atom_to_binary(R);
kind(T) when is_tuple(T), tuple_size(T) > 0, is_atom(element(1, T)) ->
    atom_to_binary(element(1, T));
kind(_) ->
    <<"signing_error">>.

%% Like the sibling's minimal PEM reader: any armor label, the base64 body
%% between the `-----` lines; PKCS#8 first, else the bare form (PKCS#1 RSA or
%% SEC1 EC).
private_key(Pem, BareType) ->
    Lines = [string:trim(L) || L <- binary:split(Pem, [<<"\r\n">>, <<"\n">>, <<"\r">>], [global])],
    B64 = iolist_to_binary([L || L <- Lines, L =/= <<>>, not is_armor(L)]),
    B64 =/= <<>> orelse erlang:error(no_key_body),
    Der = base64:mime_decode(B64),
    try
        public_key:der_decode('PrivateKeyInfo', Der)
    catch
        _:_ -> public_key:der_decode(BareType, Der)
    end.

is_armor(<<"-----", _/binary>>) -> true;
is_armor(_) -> false.

signing_input(Header, Claims) ->
    <<(b64url(kv_json(Header)))/binary, ".", (b64url(kv_json(Claims)))/binary>>.

kv_json(Pairs) -> iolist_to_binary(json:encode_key_value_list(Pairs, fun json:encode_value/2)).

b64url(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).
