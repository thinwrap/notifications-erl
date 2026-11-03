-module(thinwrap_notifications_token_cache).
-moduledoc false.

%% The bring-your-own token cache seam for the OAuth/JWT providers (FCM, APNs).
%% The wrapper holds no token state: without a `token_cache` in the config a
%% connector signs fresh on every send. With one, the connector asks the
%% caller's `get` first and hands a freshly minted token to the caller's `set`.
%% On a vendor 401/403 nothing is evicted — eviction policy is the caller's.
%%
%% Shape (validated by `thinwrap_notifications_input`):
%%
%%   #{get := fun((Key :: binary()) -> {ok, {Token :: binary(), ExpiresAt :: number()}} | error),
%%     set := fun((Key :: binary(), Token :: binary(), ExpiresAt :: number()) -> term())}
%%
%% `ExpiresAt` is an absolute Unix time in seconds (integer or float).

-export([lookup/2, store/4, now_seconds/0]).

-doc false.
%% `{ok, Token}` for an unexpired cached token, else `miss` (no cache, a cache
%% miss, or an expired entry).
-spec lookup(thinwrap_notifications:config(), binary()) -> {ok, binary()} | miss.
lookup(#{token_cache := #{get := Get}}, Key) ->
    case Get(Key) of
        {ok, {Token, ExpiresAt}} when is_binary(Token), is_number(ExpiresAt) ->
            case now_seconds() < ExpiresAt of
                true -> {ok, Token};
                false -> miss
            end;
        error ->
            miss;
        Other ->
            %% A cache that breaks its contract is a bug in the calling code.
            erlang:error({bad_token_cache_return, shape(Other)})
    end;
lookup(_Config, _Key) ->
    miss.

-doc false.
%% Hand a freshly minted token to the caller's cache, if any.
-spec store(thinwrap_notifications:config(), binary(), binary(), number()) -> ok.
store(#{token_cache := #{set := Set}}, Key, Token, ExpiresAt) ->
    _ = Set(Key, Token, ExpiresAt),
    ok;
store(_Config, _Key, _Token, _ExpiresAt) ->
    ok.

-doc false.
%% Unix time in (fractional) seconds, the unit of `ExpiresAt`.
-spec now_seconds() -> float().
now_seconds() -> erlang:system_time(millisecond) / 1000.

%% Never echo the value itself: it is (or holds) a bearer token.
shape(T) when is_tuple(T) -> {tuple, tuple_size(T)};
shape(T) when is_atom(T) -> T;
shape(_) -> other.
