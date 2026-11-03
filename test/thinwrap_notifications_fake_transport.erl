-module(thinwrap_notifications_fake_transport).
-moduledoc false.

%% Test transport: returns queued responses in order (repeating the last once
%% exhausted) and records every request. A queued item is either a response
%% map or `{error, Reason}`. Backed by a small linked process so the recorded
%% calls survive across the connector's call stack.

-behaviour(thinwrap_notifications_transport).

-export([request/2]).
-export([start/1, config/2, calls/1, last/1, stop/1]).
-export([
    resp/2, resp/3,
    qget/2,
    path_of/1,
    host_of/1,
    body_json/1,
    body_form/1,
    body_form_single/1,
    header/2,
    header_names/1
]).

%% A caller fails loudly instead of hanging the suite if the fake has died.
-define(REPLY_TIMEOUT, 5000).
-define(IDLE_TIMEOUT, 60000).

start(Responses) ->
    spawn_link(fun() -> loop(Responses, []) end).

%% `Config` with this fake as its transport.
config(Config, Responses) ->
    Pid = start(Responses),
    {Config#{transport => {?MODULE, Pid}}, Pid}.

request(Req, Pid) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, Req},
    receive
        {Ref, Reply} -> Reply
    after ?REPLY_TIMEOUT -> error(fake_transport_not_responding)
    end.

calls(Pid) ->
    Ref = make_ref(),
    Pid ! {calls, self(), Ref},
    receive
        {Ref, Calls} -> Calls
    after ?REPLY_TIMEOUT -> error(fake_transport_not_responding)
    end.

last(Pid) -> lists:last(calls(Pid)).

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ok.

loop(Queue, Calls) ->
    receive
        {request, From, Ref, Req} ->
            Idx = length(Calls),
            Reply =
                case Queue of
                    [] -> {ok, #{status => 200, headers => #{}, body => <<>>}};
                    _ when Idx < length(Queue) -> reply(lists:nth(Idx + 1, Queue));
                    _ -> reply(lists:last(Queue))
                end,
            From ! {Ref, Reply},
            loop(Queue, Calls ++ [Req]);
        {calls, From, Ref} ->
            From ! {Ref, Calls},
            loop(Queue, Calls)
    after ?IDLE_TIMEOUT ->
        %% Every test finishes in milliseconds, so an idle fake was leaked by
        %% a test that never called stop/1; a normal exit spares its linked
        %% owner.
        ok
    end.

reply({error, _} = E) -> E;
reply(#{} = Resp) -> {ok, Resp}.

resp(Status, Body) -> resp(Status, Body, #{}).

resp(Status, Body, Headers) ->
    #{
        status => Status,
        headers => maps:from_list([
            {string:lowercase(thinwrap_notifications_util:bin(K)), V}
         || K := V <- Headers
        ]),
        body => iolist_to_binary(Body)
    }.

query_pairs(#{url := Url}) ->
    case uri_string:parse(Url) of
        #{query := Q} -> uri_string:dissect_query(Q);
        _ -> []
    end.

qget(Req, Key) ->
    case lists:keyfind(Key, 1, query_pairs(Req)) of
        {_, V} -> V;
        false -> <<>>
    end.

path_of(#{url := Url}) -> maps:get(path, uri_string:parse(Url)).

host_of(#{url := Url}) ->
    case uri_string:parse(Url) of
        #{host := H, port := P} -> <<H/binary, ":", (integer_to_binary(P))/binary>>;
        #{host := H} -> H
    end.

body_json(#{body := B}) -> json:decode(B).

%% Multi-value aware: #{Key => [Values]} in order.
body_form(#{body := B}) ->
    lists:foldl(
        fun({K, V}, Acc) -> maps:update_with(K, fun(L) -> L ++ [V] end, [V], Acc) end,
        #{},
        uri_string:dissect_query(B)
    ).

body_form_single(Req) -> maps:map(fun(_K, [V | _]) -> V end, body_form(Req)).

%% Case-insensitive request-header lookup.
header(#{headers := H}, Name) ->
    Lower = string:lowercase(Name),
    case [V || K := V <- H, string:lowercase(K) =:= Lower] of
        [V | _] -> V;
        [] -> undefined
    end.

%% Lower-cased header names, one entry per header actually sent.
header_names(#{headers := H}) -> [string:lowercase(K) || K <- maps:keys(H)].
