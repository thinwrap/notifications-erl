-module(thinwrap_notifications_casing).
-moduledoc false.

%% Key-casing transforms. Seven connectors (Postmark and Twilio = pascal;
%% Mailtrap, SparkPost, SendGrid, MailerSend and Scaleway = snake) rewrite the
%% TOP-LEVEL keys of the caller's `passthrough.body`, matching the TypeScript
%% sibling; every other connector sends passthrough keys exactly as given. Do
%% not add the transform to another connector.

-export([to_casing/2, transform_keys/3, transform_passthrough_body_top_level/2]).

-export_type([casing/0]).

-type casing() :: camel | pascal | snake | kebab | constant.

-doc false.
-spec to_casing(binary(), casing()) -> binary().
to_casing(Key, Casing) ->
    Words = split_words(Key),
    iolist_to_binary(
        case Casing of
            pascal ->
                [title(W) || W <- Words];
            snake ->
                lists:join(<<"_">>, [string:lowercase(W) || W <- Words]);
            kebab ->
                lists:join(<<"-">>, [string:lowercase(W) || W <- Words]);
            constant ->
                lists:join(<<"_">>, [string:uppercase(W) || W <- Words]);
            camel ->
                case Words of
                    [] -> [];
                    [First | Rest] -> [string:lowercase(First) | [title(W) || W <- Rest]]
                end
        end
    ).

%% `HTTPServer` -> [HTTP, Server]; `dynamicTemplateData` -> [dynamic, Template,
%% Data]; `-`, `_` and whitespace separate words.
split_words(Key) ->
    S1 = re:replace(Key, "([a-z0-9])([A-Z])", "\\1\x00\\2", [global, {return, binary}]),
    S2 = re:replace(S1, "([A-Z]+)([A-Z][a-z])", "\\1\x00\\2", [global, {return, binary}]),
    S3 = re:replace(S2, "[-_\\s]+", "\x00", [global, unicode, ucp, {return, binary}]),
    [W || W <- binary:split(S3, <<0>>, [global]), W =/= <<>>].

%% `W` is a UTF-8 binary, so the rest after its first grapheme is one too.
title(W) ->
    case string:next_grapheme(W) of
        [First | Rest] when is_binary(Rest) ->
            Upper = string:uppercase(grapheme_binary(First)),
            Lower = string:lowercase(Rest),
            <<Upper/binary, Lower/binary>>;
        [] ->
            W
    end.

%% A grapheme cluster (one code point or several) as UTF-8. Its code points
%% came out of a UTF-8 binary, so the error branch is unreachable.
grapheme_binary(G) ->
    case unicode:characters_to_binary([G]) of
        B when is_binary(B) -> B;
        _ -> erlang:error(badarg, [G])
    end.

-doc false.
%% Rewrite every key of `Obj` (recursing into nested maps when `Deep`).
-spec transform_keys(map(), casing(), boolean()) -> map().
transform_keys(Obj, Casing, Deep) ->
    maps:fold(
        fun(K, V, Acc) ->
            NK = to_casing(thinwrap_notifications_util:bin(K), Casing),
            case Deep andalso is_map(V) of
                true -> Acc#{NK => transform_keys(V, Casing, Deep)};
                false -> Acc#{NK => V}
            end
        end,
        #{},
        Obj
    ).

-doc false.
%% `Input` with only its TOP-LEVEL passthrough body keys rewritten. Nested
%% maps — SendGrid `dynamic_template_data`, SparkPost `substitution_data`,
%% Postmark `TemplateModel` — pass through VERBATIM: their keys are the
%% caller's data (template variables, metadata) and must reach the provider
%% unchanged.
-spec transform_passthrough_body_top_level(map(), casing()) -> map().
transform_passthrough_body_top_level(Input, Casing) ->
    case thinwrap_notifications_passthrough:body(Input) of
        Empty when map_size(Empty) =:= 0 ->
            Input;
        Body ->
            thinwrap_notifications_passthrough:set_body(
                Input, transform_keys(Body, Casing, false)
            )
    end.
