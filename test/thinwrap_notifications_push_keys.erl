-module(thinwrap_notifications_push_keys).
-moduledoc false.

%% Test keys for the FCM (RS256) and APNs (ES256) tests, generated at run time
%% (never committed: secret scanners flag PEMs) and cached per VM, plus JWT
%% verification with `public_key:verify/4`.

-include_lib("public_key/include/public_key.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([rsa_pem/0, rsa_pem/1, ec_pem/0, ec_pem/1, p384_pem/0, armored/1, pem_body_lines/1]).
-export([verify_rs256/1, verify_es256/1, jwt_header/1, jwt_claims/1]).
-export([mem_cache/0, cache_entries/1]).

rsa() -> cached(rsa, fun() -> public_key:generate_key({rsa, 2048, 65537}) end).
ec() -> cached(ec, fun() -> public_key:generate_key({namedCurve, secp256r1}) end).

cached(K, F) ->
    case persistent_term:get({?MODULE, K}, undefined) of
        undefined ->
            V = F(),
            persistent_term:put({?MODULE, K}, V),
            V;
        V ->
            V
    end.

%% PKCS#8 (`BEGIN PRIVATE KEY`), the service-account / .p8 form.
rsa_pem() -> rsa_pem(pkcs8).
rsa_pem(pkcs8) -> pem('PrivateKeyInfo', rsa());
rsa_pem(pkcs1) -> pem('RSAPrivateKey', rsa()).

ec_pem() -> ec_pem(pkcs8).
ec_pem(pkcs8) -> pem('PrivateKeyInfo', ec());
ec_pem(sec1) -> pem('ECPrivateKey', ec()).

p384_pem() ->
    pem(
        'PrivateKeyInfo',
        cached(p384, fun() -> public_key:generate_key({namedCurve, secp384r1}) end)
    ).

pem(Type, Key) -> public_key:pem_encode([public_key:pem_entry_encode(Type, Key)]).

%% Arbitrary (non-key) DER bytes in PKCS#8 armor, for the malformed-key cases.
armored(Der) -> public_key:pem_encode([{'PrivateKeyInfo', Der, not_encrypted}]).

%% The base64 body lines of a PEM (what must never appear in an error).
pem_body_lines(Pem) ->
    [
        L
     || L0 <- binary:split(Pem, <<"\n">>, [global]),
        L <- [string:trim(L0)],
        L =/= <<>>,
        binary:match(L, <<"-----">>) =:= nomatch
    ].

parts(Jwt) ->
    [H, C, S] = binary:split(Jwt, <<".">>, [global]),
    {<<H/binary, ".", C/binary>>, b64(H), b64(C), b64(S)}.

b64(B) -> base64:decode(B, #{mode => urlsafe, padding => false}).

jwt_header(Jwt) ->
    {_, H, _, _} = parts(Jwt),
    json:decode(H).

jwt_claims(Jwt) ->
    {_, _, C, _} = parts(Jwt),
    json:decode(C).

verify_rs256(Jwt) ->
    {Input, _, _, Sig} = parts(Jwt),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = rsa(),
    public_key:verify(Input, sha256, Sig, #'RSAPublicKey'{modulus = N, publicExponent = E}).

%% ES256 signatures are raw r||s (64 bytes); public_key verifies DER.
verify_es256(Jwt) ->
    {Input, _, _, Sig} = parts(Jwt),
    ?assertEqual(64, byte_size(Sig)),
    <<R:256, S:256>> = Sig,
    Der = public_key:der_encode('ECDSA-Sig-Value', #'ECDSA-Sig-Value'{r = R, s = S}),
    #'ECPrivateKey'{publicKey = Pub, parameters = Params} = ec(),
    public_key:verify(Input, sha256, Der, {#'ECPoint'{point = Pub}, Params}).

%% A tiny in-memory token cache (`#{get, set}`) backed by a linked
%% process, plus a reader for what was stored.
mem_cache() ->
    Pid = spawn_link(fun() -> cache_loop(#{}) end),
    Cache = #{
        get => fun(K) ->
            case call(Pid, {get, K}) of
                undefined -> error;
                V -> {ok, V}
            end
        end,
        set => fun(K, T, Exp) -> call(Pid, {set, K, {T, Exp}}) end
    },
    {Cache, Pid}.

cache_entries(Pid) -> call(Pid, all).

call(Pid, Msg) ->
    Ref = make_ref(),
    Pid ! {Ref, self(), Msg},
    receive
        {Ref, R} -> R
        %% A caller fails loudly instead of hanging the suite if the cache died.
    after 5000 -> error(token_cache_not_responding)
    end.

cache_loop(M) ->
    receive
        {Ref, From, {get, K}} ->
            From ! {Ref, maps:get(K, M, undefined)},
            cache_loop(M);
        {Ref, From, {set, K, V}} ->
            From ! {Ref, ok},
            cache_loop(M#{K => V});
        {Ref, From, all} ->
            From ! {Ref, M},
            cache_loop(M)
    after 60000 ->
        %% Every test finishes in milliseconds, so an idle cache was leaked;
        %% a normal exit spares its linked owner.
        ok
    end.
