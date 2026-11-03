-module(thinwrap_notifications_sigv4).
-moduledoc false.

%% Hand-rolled AWS Signature Version 4 (HMAC-SHA256) on OTP `crypto` — no
%% third-party dependency. Used by the SES and SNS connectors.

-export([sign/1, validate_region/2, with_signed_headers/2, build_canonical_query/1]).

-export_type([params/0]).

-type params() :: #{
    method := binary(),
    %% <<"ses">> | <<"sns">>
    service := binary(),
    region := binary(),
    host := binary(),
    %% e.g. <<"/v2/email/outbound-emails">> (no query)
    path := binary(),
    payload := binary(),
    access_key_id := binary(),
    secret_access_key := binary(),
    session_token => binary(),
    %% sorted, RFC 3986-encoded, no leading "?"
    canonical_query => binary(),
    %% extra signed headers, e.g. Content-Type
    signed => #{binary() => term()},
    %% UTC; defaults to now
    now => calendar:datetime()
}.

%% Hop-by-hop / runtime-owned headers never folded into the signature. Mirrors
%% @smithy/signature-v4 ALWAYS_UNSIGNABLE_HEADERS plus content-length.
%% Content-Type is deliberately NOT here — AWS requires it signed when present.
-define(UNSIGNABLE, [
    <<"authorization">>,
    <<"cache-control">>,
    <<"connection">>,
    <<"content-length">>,
    <<"expect">>,
    <<"from">>,
    <<"keep-alive">>,
    <<"max-forwards">>,
    <<"pragma">>,
    <<"proxy-authenticate">>,
    <<"proxy-authorization">>,
    <<"referer">>,
    <<"te">>,
    <<"trailer">>,
    <<"transfer-encoding">>,
    <<"upgrade">>,
    <<"user-agent">>,
    <<"x-amzn-trace-id">>
]).

-doc false.
%% The headers to attach to the request: Host, X-Amz-Date,
%% X-Amz-Content-Sha256, Authorization and (with a session token)
%% X-Amz-Security-Token. Signed values are not caller-overridable.
-spec sign(params()) -> #{binary() => binary()}.
sign(P) ->
    {{Y, Mo, D}, {H, Mi, S}} = maps:get(now, P, calendar:universal_time()),
    DateStamp = iolist_to_binary(io_lib:format("~4..0B~2..0B~2..0B", [Y, Mo, D])),
    AmzDate = iolist_to_binary([DateStamp, io_lib:format("T~2..0B~2..0B~2..0BZ", [H, Mi, S])]),
    HashedPayload = hex(crypto:hash(sha256, maps:get(payload, P))),
    Token = maps:get(session_token, P, <<>>),
    Canonical0 = maps:fold(
        fun(K, V, Acc) -> Acc#{string:lowercase(thinwrap_notifications_util:bin(K)) => ws(V)} end,
        #{},
        maps:get(signed, P, #{})
    ),
    Canonical1 = Canonical0#{
        <<"host">> => ws(maps:get(host, P)),
        <<"x-amz-date">> => AmzDate,
        <<"x-amz-content-sha256">> => HashedPayload
    },
    Canonical2 =
        case Token of
            <<>> -> Canonical1;
            _ -> Canonical1#{<<"x-amz-security-token">> => Token}
        end,
    Canonical = maps:without(?UNSIGNABLE, Canonical2),
    Names = lists:sort(maps:keys(Canonical)),
    CanonicalHeaders = [[N, $:, maps:get(N, Canonical), $\n] || N <- Names],
    SignedHeaders = iolist_to_binary(lists:join(<<";">>, Names)),
    CanonicalRequest = iolist_to_binary(
        lists:join(<<"\n">>, [
            maps:get(method, P),
            maps:get(path, P),
            maps:get(canonical_query, P, <<>>),
            CanonicalHeaders,
            SignedHeaders,
            HashedPayload
        ])
    ),
    Region = maps:get(region, P),
    Service = maps:get(service, P),
    Scope = <<DateStamp/binary, "/", Region/binary, "/", Service/binary, "/aws4_request">>,
    StringToSign = iolist_to_binary(
        lists:join(<<"\n">>, [
            <<"AWS4-HMAC-SHA256">>, AmzDate, Scope, hex(crypto:hash(sha256, CanonicalRequest))
        ])
    ),
    KDate = hmac(<<"AWS4", (maps:get(secret_access_key, P))/binary>>, DateStamp),
    KRegion = hmac(KDate, Region),
    KService = hmac(KRegion, Service),
    KSigning = hmac(KService, <<"aws4_request">>),
    Signature = hex(hmac(KSigning, StringToSign)),
    Authorization = iolist_to_binary([
        <<"AWS4-HMAC-SHA256 Credential=">>,
        maps:get(access_key_id, P),
        $/,
        Scope,
        <<", SignedHeaders=">>,
        SignedHeaders,
        <<", Signature=">>,
        Signature
    ]),
    Out = #{
        <<"Host">> => maps:get(host, P),
        <<"X-Amz-Date">> => AmzDate,
        <<"X-Amz-Content-Sha256">> => HashedPayload,
        <<"Authorization">> => Authorization
    },
    case Token of
        <<>> -> Out;
        _ -> Out#{<<"X-Amz-Security-Token">> => Token}
    end.

hmac(Key, Data) -> crypto:mac(hmac, sha256, Key, Data).

hex(B) -> binary:encode_hex(B, lowercase).

%% Trim, then collapse internal whitespace runs to one space.
ws(V) ->
    re:replace(
        string:trim(thinwrap_notifications_util:bin(V)),
        "\\s+",
        " ",
        [global, unicode, {return, binary}]
    ).

-doc false.
%% Reject a region that is not a single AWS region label (botocore
%% `validate_region_name`). The region is interpolated into the request host,
%% so a value like `x.evil.com/` would send a SigV4-signed request (and any
%% session token) to another host. Whole-string anchored: a trailing newline
%% from an env file is rejected too.
-spec validate_region(binary(), binary()) -> ok.
validate_region(Region, Provider) ->
    case re:run(Region, "^(?![0-9]+\\z)(?!-)[a-zA-Z0-9-]{1,63}(?<!-)\\z", [{capture, none}]) of
        match ->
            ok;
        nomatch ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:invalid_request(
                    iolist_to_binary([
                        "Invalid ",
                        Provider,
                        " region ",
                        thinwrap_notifications_util:py_repr(Region),
                        "; expected an AWS region such as 'us-east-1'."
                    ])
                )
            )
    end.

-doc false.
%% Overlay the SigV4 headers on the request headers. HTTP names are
%% case-insensitive, so a caller `authorization` or `x-amz-date` is dropped
%% rather than sent next to the signed `Authorization`.
-spec with_signed_headers(map(), #{binary() => binary()}) -> map().
with_signed_headers(Headers, Signed) ->
    Owned = [string:lowercase(K) || K <- maps:keys(Signed)],
    Kept = maps:filter(
        fun(K, _) ->
            not lists:member(string:lowercase(thinwrap_notifications_util:bin(K)), Owned)
        end,
        Headers
    ),
    maps:merge(Kept, Signed).

-doc false.
%% SigV4 canonical query string: keys sorted, each key/value RFC 3986-encoded,
%% joined `k=v&...`; empty for no query. Append the same string to the URL.
-spec build_canonical_query(thinwrap_notifications_util:query()) -> binary().
build_canonical_query(Query) ->
    iolist_to_binary(
        lists:join(<<"&">>, [
            [rfc3986(K), $=, rfc3986(V)]
         || {K, V} <- lists:keysort(1, Query)
        ])
    ).

%% RFC 3986 unreserved (ALPHA / DIGIT / - . _ ~) literal, all else %XX.
rfc3986(S) -> thinwrap_notifications_util:quote(thinwrap_notifications_util:bin(S), <<>>).
