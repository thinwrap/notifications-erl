-module(thinwrap_notifications_passthrough).
-moduledoc false.

%% The per-send input escape hatch. `body` is deep-merged into the connector's
%% request body (maps recurse, everything else replaces); `headers` and
%% `query` are shallow-merged. Caller values intentionally OVERRIDE
%% connector-set ones (auth included) — there is deliberately no reserved-key
%% protection. Header names match case-insensitively and the caller's spelling
%% is the one sent. Body and query keys may be atoms or binaries; they go on
%% the wire exactly as given (only the connectors listed in
%% `thinwrap_notifications_casing` rewrite top-level body keys first).

-export([merge/4, merge_form/2, body/1, set_body/2]).

-doc false.
-spec merge(
    map(),
    thinwrap_notifications_transport:headers(),
    thinwrap_notifications_util:query(),
    map()
) -> {map(), map(), thinwrap_notifications_util:query()}.
merge(Body, Headers, Query, Input) ->
    Pt = maps:get(passthrough, Input, #{}),
    {
        deep_merge(Body, body(Input)),
        thinwrap_notifications_http:merge_headers(Headers, maps:get(headers, Pt, #{})),
        merge_query(Query, maps:get(query, Pt, #{}))
    }.

-doc false.
%% The passthrough body overlaid onto an ORDERED form field list (form and
%% multipart vendors, where field order is kept as built): a same-named field
%% is replaced in place, a new one appended. Map values on both sides
%% deep-merge, as in `merge/4`.
-spec merge_form([{binary(), term()}], map()) -> [{binary(), term()}].
merge_form(Fields, Input) ->
    lists:foldl(
        fun({K, V}, Acc) ->
            case lists:keyfind(K, 1, Acc) of
                {K, #{} = Existing} when is_map(V) ->
                    lists:keyreplace(K, 1, Acc, {K, deep_merge(Existing, V)});
                {K, _} ->
                    lists:keyreplace(K, 1, Acc, {K, V});
                false ->
                    Acc ++ [{K, V}]
            end
        end,
        Fields,
        lists:sort(maps:to_list(body(Input)))
    ).

-doc false.
%% The caller's passthrough body alone, keys as binaries (nested too).
-spec body(map()) -> map().
body(Input) ->
    keys_to_binary(maps:get(body, maps:get(passthrough, Input, #{}), #{})).

-doc false.
%% `Input` with its passthrough body replaced (used by the casing transform).
-spec set_body(map(), map()) -> map().
set_body(Input, Body) ->
    Pt = maps:get(passthrough, Input, #{}),
    Input#{passthrough => Pt#{body => Body}}.

deep_merge(Target, Source) ->
    maps:fold(
        fun(K, V, Acc) ->
            case {V, maps:get(K, Acc, undefined)} of
                {#{}, #{} = Existing} -> Acc#{K => deep_merge(Existing, V)};
                _ -> Acc#{K => V}
            end
        end,
        Target,
        Source
    ).

%% Same-named keys replaced in place, new ones appended (sorted, a map has no
%% order). Query keys are case-sensitive, as query parameters are.
merge_query(Base, Override) ->
    lists:foldl(
        fun({K0, V0}, Acc) ->
            K = thinwrap_notifications_util:bin(K0),
            V = thinwrap_notifications_util:bin(V0),
            case lists:keymember(K, 1, Acc) of
                true -> lists:keyreplace(K, 1, Acc, {K, V});
                false -> Acc ++ [{K, V}]
            end
        end,
        Base,
        lists:sort(maps:to_list(Override))
    ).

keys_to_binary(M) when is_map(M) ->
    maps:fold(
        fun(K, V, Acc) -> Acc#{key(K) => keys_to_binary(V)} end,
        #{},
        M
    );
keys_to_binary(L) when is_list(L) ->
    [keys_to_binary(V) || V <- L];
keys_to_binary(V) ->
    V.

key(A) when is_atom(A) -> atom_to_binary(A);
key(K) -> K.
