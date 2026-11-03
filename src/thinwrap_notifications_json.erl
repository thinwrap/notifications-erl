-module(thinwrap_notifications_json).
-moduledoc false.

%% JSON on OTP's own `json` module (OTP 27+), plus absence-tolerant accessors
%% for walking a decoded vendor body on the error and raw paths, where full
%% typing would be overkill.
%%
%% Decoded shape: objects are maps with binary keys, arrays are lists, `null`
%% is the atom `null`, numbers stay integer or float as written.

-export([encode/1, encode_failure/1, decode/1, get/2, str/1, num/1, list/1, path/2]).

-doc false.
%% Compact UTF-8 JSON, non-ASCII kept as-is (like JSON.stringify and the
%% siblings' encoders). Atom keys/values other than true/false/null encode as
%% strings. A non-UTF-8 binary or an unencodable term (a tuple, a pid) is
%% request data the vendor could never accept, so it fails with
%% `invalid_request`; only the failure kind is kept, never the value, which
%% could be a credential.
-spec encode(term()) -> binary().
encode(Term) ->
    try
        %% encode/2 with the stock encoder is exactly encode/1, but typed to
        %% accept any term: an unencodable one is the error branch below.
        iolist_to_binary(json:encode(Term, fun json:encode_value/2))
    catch
        error:Reason ->
            thinwrap_notifications_error:fail(encode_failure(encode_reason(Reason)))
    end.

-doc false.
-spec encode_failure(binary()) -> thinwrap_notifications:connector_error().
encode_failure(Kind) ->
    thinwrap_notifications_error:new(invalid_request, #{
        message => <<"Failed to encode request body">>,
        provider_message => <<"Failed to encode request body">>,
        cause => #{<<"raw">> => #{<<"exception">> => Kind}}
    }).

encode_reason({invalid_byte, _}) -> <<"invalid_byte">>;
encode_reason({unsupported_type, _}) -> <<"unsupported_type">>;
encode_reason(R) when is_atom(R) -> atom_to_binary(R);
encode_reason(_) -> <<"encode_failed">>.

-doc false.
%% Decode arbitrary JSON; `null` for an empty or malformed body (the Python
%% sibling's `None`). OTP's decoder already rejects the non-JSON
%% NaN/Infinity tokens and out-of-range numbers such as `1e999`.
-spec decode(binary() | undefined) -> term().
decode(undefined) ->
    null;
decode(<<>>) ->
    null;
decode(Bin) when is_binary(Bin) ->
    try
        json:decode(Bin)
    catch
        error:_ -> null
    end.

-doc false.
-spec get(term(), binary()) -> term() | undefined.
get(#{} = M, Key) ->
    case maps:get(Key, M, undefined) of
        null -> undefined;
        V -> V
    end;
get(_, _) ->
    undefined.

-doc false.
%% Walk nested object keys; any non-object along the way yields `undefined`.
-spec path(term(), [binary()]) -> term() | undefined.
path(V, []) -> V;
path(V, [K | Rest]) -> path(get(V, K), Rest).

-doc false.
%% A JSON string, else `<<>>`.
-spec str(term()) -> binary().
str(B) when is_binary(B) -> B;
str(_) -> <<>>.

-doc false.
%% A JSON number as a float, `0.0` when absent or not a number. BEAM floats are
%% always finite, so there is no NaN/Infinity case to neutralize.
-spec num(term()) -> float().
num(N) when is_number(N) -> float(N);
num(_) -> 0.0.

-doc false.
-spec list(term()) -> list() | undefined.
list(L) when is_list(L) -> L;
list(_) -> undefined.
