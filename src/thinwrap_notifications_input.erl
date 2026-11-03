-module(thinwrap_notifications_input).
-moduledoc false.

%% Validation and defaults for configs and send inputs. Everything here is
%% misuse detection, so every failure raises `{badarg, Description}` before
%% any HTTP — never a connector error. Descriptions never echo a config
%% value: it may be a credential.
%%
%% ?PROVIDERS is the single provider table: channel, required config keys,
%% optional config keys, and which of those keys are credentials (a binary or
%% a fun/0). It mirrors the Python sibling's config dataclasses field for
%% field (`from_` is `from` here: not a reserved word in Erlang).

-export([config/2, input/2, secret/2, providers/0, channel_of/1]).

-define(EMAIL_OPT, [from, sender_name]).

-define(PROVIDERS, #{
    %% Email
    ses =>
        {email, [region, access_key_id, secret_access_key],
            [session_token, from, sender_name, configuration_set_name], [
                access_key_id, secret_access_key, session_token
            ]},
    resend => {email, [api_key], ?EMAIL_OPT, [api_key]},
    mailgun => {email, [api_key, domain], ?EMAIL_OPT ++ [region, username, base_url], [api_key]},
    sendgrid => {email, [api_key], ?EMAIL_OPT, [api_key]},
    postmark => {email, [server_token], ?EMAIL_OPT ++ [message_stream], [server_token]},
    mailersend => {email, [api_token], ?EMAIL_OPT, [api_token]},
    mailtrap => {email, [api_token], [mode, inbox_id] ++ ?EMAIL_OPT, [api_token]},
    brevo => {email, [api_key], ?EMAIL_OPT, [api_key]},
    sparkpost => {email, [api_key], ?EMAIL_OPT ++ [region], [api_key]},
    scaleway => {email, [secret_key, project_id], ?EMAIL_OPT ++ [region], [secret_key]},
    %% SMS
    vonage => {sms, [api_key, api_secret], [from], [api_key, api_secret]},
    twilio => {sms, [account_sid, auth_token], [from, region, edge], [auth_token]},
    plivo => {sms, [auth_id, auth_token], [from], [auth_token]},
    sns =>
        {sms, [region, access_key_id, secret_access_key], [session_token], [
            access_key_id, secret_access_key, session_token
        ]},
    sinch => {sms, [service_plan_id, api_token], [from, region], [api_token]},
    telnyx => {sms, [api_key], [from], [api_key]},
    infobip => {sms, [base_url, api_key], [from], [api_key]},
    messagebird => {sms, [access_key], [from], [access_key]},
    textmagic => {sms, [username, api_key], [from], [api_key]},
    d7networks => {sms, [api_token], [from], [api_token]},
    %% Push
    fcm => {push, [project_id, client_email, private_key], [token_cache], [private_key]},
    expo => {push, [], [access_token], [access_token]},
    apns => {push, [team_id, key_id, private_key, bundle_id], [env, token_cache], [private_key]},
    'one-signal' => {push, [app_id, api_key], [], [api_key]},
    'pusher-beams' => {push, [instance_id, secret_key], [], [secret_key]},
    wonderpush => {push, [access_token], [application_id], [access_token]},
    %% Chat (a webhook URL embeds its token, so it is a credential)
    telegram => {chat, [bot_token], [], [bot_token]},
    slack => {chat, [webhook_url], [], [webhook_url]},
    'whatsapp-business' =>
        {chat, [access_token, phone_number_id], [graph_api_version], [access_token]},
    discord => {chat, [webhook_url], [], [webhook_url]},
    'ms-teams' => {chat, [webhook_url], [], [webhook_url]},
    'google-chat' => {chat, [webhook_url], [], [webhook_url]},
    mattermost => {chat, [webhook_url], [], [webhook_url]},
    'rocket-chat' => {chat, [webhook_url], [], [webhook_url]},
    line => {chat, [channel_access_token], [], [channel_access_token]}
}).

-doc false.
%% Every provider, sorted.
-spec providers() -> [thinwrap_notifications:provider()].
providers() -> lists:sort(maps:keys(?PROVIDERS)).

-doc false.
-spec channel_of(atom()) -> thinwrap_notifications:channel() | undefined.
channel_of(P) ->
    case ?PROVIDERS of
        #{P := {Channel, _, _, _}} -> Channel;
        _ -> undefined
    end.

-doc false.
-spec config(thinwrap_notifications:channel(), term()) -> thinwrap_notifications:config().
config(Channel, #{provider := P} = C) ->
    case ?PROVIDERS of
        #{P := {Channel, Required, Optional, Creds}} ->
            Allowed = [provider, transport] ++ Required ++ Optional,
            [
                bad(["unknown config key for ", name(P), ": ", key_text(K)])
             || K <- maps:keys(C), not lists:member(K, Allowed)
            ],
            [
                bad([name(P), " config requires ", atom_to_list(K)])
             || K <- Required, not maps:is_key(K, C)
            ],
            [check_value(K, V, Creds) || K := V <- C, K =/= provider, K =/= transport],
            checked_config(C#{transport => transport(maps:get(transport, C, undefined))});
        #{P := _} ->
            bad([name(P), " is not a ", atom_to_list(Channel), " provider"]);
        _ ->
            bad(["config provider must be one of ", join(providers())])
    end;
config(Channel, _) ->
    bad(["send_", atom_to_list(Channel), " requires a config map with a provider key"]).

%% config/2 has checked every key of `C` against ?PROVIDERS by now, which a
%% type checker cannot follow; this identity is the one place the validated
%% map is declared a config().
-spec checked_config(map()) -> thinwrap_notifications:config().
checked_config(C) -> C.

check_value(token_cache, #{get := G, set := S} = TC, _Creds) when
    is_function(G, 1), is_function(S, 3), map_size(TC) =:= 2
->
    ok;
check_value(token_cache, _, _Creds) ->
    bad(["config token_cache must be #{get => fun/1, set => fun/3}"]);
check_value(K, V, Creds) ->
    case lists:member(K, Creds) of
        true when is_binary(V); is_function(V, 0) -> ok;
        true -> bad(["config ", atom_to_list(K), " must be a binary or a fun/0"]);
        false when is_binary(V) -> ok;
        false -> bad(["config ", atom_to_list(K), " must be a binary"])
    end.

transport(undefined) ->
    {thinwrap_notifications_httpc, #{}};
transport({Mod, _Opts} = T) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} -> ok;
        _ -> bad(["transport module ", atom_to_list(Mod), " cannot be loaded"])
    end,
    erlang:function_exported(Mod, request, 2) orelse
        bad(["transport module ", atom_to_list(Mod), " does not export request/2"]),
    T;
transport(_) ->
    bad(["config transport must be {Module, Opts}"]).

-doc false.
%% Resolve a credential (binary or fun/0) at the point of use; an absent
%% optional credential is `<<>>`, the Python sibling's empty-string default.
-spec secret(thinwrap_notifications:config(), atom()) -> binary().
secret(Config, Key) ->
    case maps:get(Key, Config, <<>>) of
        F when is_function(F, 0) ->
            case F() of
                B when is_binary(B) -> B;
                _ -> bad(["config ", atom_to_list(Key), " fun must return a binary"])
            end;
        B when is_binary(B) ->
            B;
        %% Unreachable after config/2, which allows only a binary or a fun/0.
        _ ->
            bad(["config ", atom_to_list(Key), " must be a binary or a fun/0"])
    end.

%% ---------------------------------------------------------------------------
%% Inputs: {Key, Default, Check}. Every key is optional with the Python
%% sibling's default, so connectors read them with `:=`. An empty recipient is
%% not misuse here: as in the siblings, a connector that needs one rejects it
%% with `invalid_request`.

spec(email) ->
    [
        {to, <<>>, binary},
        {subject, <<>>, binary},
        {from, <<>>, binary},
        {cc, [], {list, binary}},
        {bcc, [], {list, binary}},
        {reply_to, <<>>, binary},
        {text, <<>>, binary},
        {html, <<>>, binary},
        {attachments, [], {list, attachment}},
        {headers, #{}, string_map},
        {tags, [], {list, binary}},
        {passthrough, #{}, passthrough}
    ];
spec(sms) ->
    [
        {to, <<>>, binary},
        {body, <<>>, binary},
        {from, <<>>, binary},
        {passthrough, #{}, passthrough}
    ];
spec(push) ->
    [
        {to, <<>>, binary},
        {title, <<>>, binary},
        {body, <<>>, binary},
        {data, #{}, string_map},
        {passthrough, #{}, passthrough}
    ];
spec(chat) ->
    [
        {body, <<>>, binary},
        {to, <<>>, binary},
        {passthrough, #{}, passthrough}
    ].

-doc false.
%% The validated input with every default filled in (attachments too).
-spec input(thinwrap_notifications:channel(), term()) -> map().
input(Channel, Input) when is_map(Input) ->
    Op = ["send_", atom_to_list(Channel)],
    Spec = spec(Channel),
    Known = [K || {K, _, _} <- Spec],
    [
        bad([Op, ": unknown input key ", key_text(K)])
     || K <- maps:keys(Input), not lists:member(K, Known)
    ],
    lists:foldl(
        fun({K, Default, Check}, Acc) ->
            case maps:find(K, Input) of
                {ok, V} ->
                    valid(Check, V) orelse
                        bad([Op, ": ", atom_to_list(K), " must be ", describe(Check)]),
                    Acc#{K => normalize(Check, V)};
                error ->
                    Acc#{K => Default}
            end
        end,
        #{},
        Spec
    );
input(Channel, _) ->
    bad(["send_", atom_to_list(Channel), ": input must be a map"]).

valid(binary, V) ->
    is_binary(V);
valid(string_map, #{} = M) ->
    lists:all(fun({K, V}) -> is_binary(K) andalso is_binary(V) end, maps:to_list(M));
valid(string_map, _) ->
    false;
valid({list, C}, L) when is_list(L) -> lists:all(fun(V) -> valid(C, V) end, L);
valid({list, _}, _) ->
    false;
valid(attachment, #{filename := F, content := B} = A) when is_binary(F), is_binary(B) ->
    lists:all(
        fun
            ({K, _}) when K =:= filename; K =:= content -> true;
            ({K, V}) when K =:= content_type; K =:= content_id -> is_binary(V);
            (_) -> false
        end,
        maps:to_list(A)
    );
valid(attachment, _) ->
    false;
valid(passthrough, #{} = P) ->
    lists:all(fun(K) -> lists:member(K, [body, headers, query]) end, maps:keys(P)) andalso
        keyed(maps:get(body, P, #{})) andalso
        keyed(maps:get(headers, P, #{})) andalso
        query_map(maps:get(query, P, #{}));
valid(passthrough, _) ->
    false.

%% A map whose keys are atoms or binaries (header values are checked at send
%% time, where a bad one is `invalid_request` as in the siblings).
keyed(#{} = M) -> lists:all(fun(K) -> is_atom(K) orelse is_binary(K) end, maps:keys(M));
keyed(_) -> false.

query_map(#{} = M) ->
    lists:all(
        fun({K, V}) ->
            (is_atom(K) orelse is_binary(K)) andalso
                (is_binary(V) orelse is_number(V) orelse is_atom(V))
        end,
        maps:to_list(M)
    );
query_map(_) ->
    false.

normalize({list, attachment}, L) ->
    [maps:merge(#{content_type => <<>>, content_id => <<>>}, A) || A <- L];
normalize(_, V) ->
    V.

describe(binary) ->
    "a binary";
describe(string_map) ->
    "a map of binary keys to binary values";
describe({list, C}) ->
    ["a list of ", describe(C)];
describe(attachment) ->
    "#{filename := binary(), content := binary(), content_type => binary(), "
    "content_id => binary()}";
describe(passthrough) ->
    "#{body => map(), headers => map(), query => map()} with atom or binary keys".

join(Atoms) -> lists:join(", ", [name(A) || A <- Atoms]).

name(A) -> atom_to_list(A).

key_text(K) when is_atom(K) -> atom_to_list(K);
key_text(_) -> "(non-atom key)".

-spec bad(iodata()) -> no_return().
bad(IoList) ->
    erlang:error({badarg, unicode:characters_to_binary(IoList)}).
