-module(thinwrap_notifications_util).
-moduledoc false.

%% Small shared helpers: URL/form encoding, base64, mailbox formatting, MIME
%% quoting, vendor-value display. Connectors call these as building blocks;
%% nothing here intercepts a request globally.

-export([
    ok_status/1,
    build_url/2,
    urlencode/1,
    quote/2,
    encode_form/1,
    stringify_form/1,
    b64/1,
    basic_auth/2,
    strip_crlf/1,
    escape_mime_quoted/1,
    quote_mime_filename/1,
    encoded_words/1,
    format_mailbox/2,
    response_text/1,
    first_non_empty/1,
    bin/1,
    py_repr/1,
    put_opt/3,
    put_nonempty/3,
    cfg/2,
    assert_utf8/1,
    result/3
]).

-export_type([query/0]).

%% Ordered, because a stable query string keeps requests reproducible.
-type query() :: [{binary(), binary()}].

-spec ok_status(integer()) -> boolean().
ok_status(S) -> S >= 200 andalso S < 300.

-doc false.
%% Append `Query` to `Url` (`&` when the URL already has a query).
-spec build_url(binary(), query()) -> binary().
build_url(Url, []) ->
    Url;
build_url(Url, Query) ->
    case urlencode(Query) of
        <<>> ->
            Url;
        Qs ->
            Sep =
                case binary:match(Url, <<"?">>) of
                    nomatch -> <<"?">>;
                    _ -> <<"&">>
                end,
            <<Url/binary, Sep/binary, Qs/binary>>
    end.

-doc false.
%% `application/x-www-form-urlencoded` pairs exactly as Python's
%% `urllib.parse.urlencode` writes them (`quote_plus`): letters, digits and
%% `_.-~` stay literal, a space becomes `+`, everything else is `%XX` of its
%% UTF-8 bytes. A non-UTF-8 value is request data no vendor could decode, so
%% it fails with `invalid_request`.
-spec urlencode([{binary() | atom(), binary() | atom() | integer() | float() | string()}]) ->
    binary().
urlencode(Pairs) ->
    iolist_to_binary(
        lists:join(
            <<"&">>,
            [[plus_quote(bin(K)), $=, plus_quote(bin(V))] || {K, V} <- Pairs]
        )
    ).

plus_quote(B) ->
    check_utf8(B),
    <<<<(plus_byte(C))/binary>> || <<C>> <= B>>.

plus_byte($\s) -> <<"+">>;
plus_byte(C) -> quote_byte(C, <<>>).

-doc false.
%% Python's `urllib.parse.quote(S, safe=Safe)`: letters, digits, `_.-~` and the
%% `Safe` bytes stay literal; everything else is `%XX` of its UTF-8 bytes. Used
%% for config values interpolated into a URL path, where a stray `/` or `?`
%% would retarget the request.
-spec quote(binary(), binary()) -> binary().
quote(B, Safe) ->
    check_utf8(B),
    <<<<(quote_byte(C, Safe))/binary>> || <<C>> <= B>>.

quote_byte(C, _Safe) when
    C >= $a, C =< $z;
    C >= $A, C =< $Z;
    C >= $0, C =< $9;
    C =:= $_;
    C =:= $.;
    C =:= $-;
    C =:= $~
->
    <<C>>;
quote_byte(C, Safe) ->
    case binary:match(Safe, <<C>>) of
        nomatch -> iolist_to_binary(io_lib:format("%~2.16.0B", [C]));
        _ -> <<C>>
    end.

-doc false.
%% Fail with `invalid_request` unless `B` is valid UTF-8 (the Erlang analogue of
%% the siblings' lone-surrogate encode failure).
-spec assert_utf8(binary()) -> ok.
assert_utf8(B) -> check_utf8(B).

check_utf8(B) ->
    case unicode:characters_to_binary(B) of
        B ->
            ok;
        _ ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_json:encode_failure(<<"invalid_byte">>)
            )
    end.

-doc false.
%% `application/x-www-form-urlencoded` body. A list value becomes a repeated
%% field (Twilio `MediaUrl`, Mailgun `o:tag`); `null`/`undefined` is skipped;
%% everything else goes through `stringify_form/1`.
-spec encode_form([{binary(), term()}]) -> binary().
encode_form(Fields) ->
    Pairs = lists:append([
        case V of
            null -> [];
            undefined -> [];
            L when is_list(L) -> [{K, stringify_form(I)} || I <- L];
            _ -> [{K, stringify_form(V)}]
        end
     || {K, V} <- Fields
    ]),
    urlencode(Pairs).

-doc false.
%% A value as its form-field string, mirroring the siblings' String()
%% coercion. A structured value (map, list) is JSON by vendor convention
%% (Mailgun `t:variables`: "A valid JSON-encoded dictionary").
-spec stringify_form(term()) -> binary().
stringify_form(null) -> <<>>;
stringify_form(undefined) -> <<>>;
stringify_form(true) -> <<"true">>;
stringify_form(false) -> <<"false">>;
stringify_form(B) when is_binary(B) -> B;
stringify_form(I) when is_integer(I) -> integer_to_binary(I);
stringify_form(F) when is_float(F) -> float_text(F);
stringify_form(A) when is_atom(A) -> atom_to_binary(A);
stringify_form(V) -> thinwrap_notifications_json:encode(V).

%% Integral floats without the `.0`, others shortest round-trip.
float_text(F) when F == trunc(F) -> integer_to_binary(trunc(F));
float_text(F) -> float_to_binary(F, [short]).

-doc false.
%% Standard base64 of raw bytes (attachment payloads).
-spec b64(binary()) -> binary().
b64(B) -> base64:encode(B).

-doc false.
%% An HTTP Basic `Authorization` header value.
-spec basic_auth(binary(), binary()) -> binary().
basic_auth(User, Password) ->
    <<"Basic ", (base64:encode(<<User/binary, ":", Password/binary>>))/binary>>.

-doc false.
%% Replace CR/LF runs with a space and trim (header-injection guard).
-spec strip_crlf(binary()) -> binary().
strip_crlf(V) ->
    string:trim(re:replace(V, "[\r\n]+", " ", [global, unicode, {return, binary}])).

-doc false.
%% Sanitize a value for use inside a double-quoted MIME parameter
%% (`name="..."`): strip CR/LF, then backslash-escape `\` and `"` so a
%% consumer-supplied value cannot break out of the quoted string and disturb
%% multipart framing. No surrounding quotes are added.
-spec escape_mime_quoted(binary()) -> binary().
escape_mime_quoted(V) ->
    escape_backslash_and_quote(strip_crlf(V)).

%% `\` and `"` backslash-escaped, the two characters special inside a quoted
%% string (RFC 5322 quoted-string, RFC 2045 MIME parameter value).
escape_backslash_and_quote(S) ->
    S1 = binary:replace(S, <<"\\">>, <<"\\\\">>, [global]),
    binary:replace(S1, <<"\"">>, <<"\\\"">>, [global]).

-doc false.
%% A MIME filename quoted per RFC 2183.
-spec quote_mime_filename(binary()) -> binary().
quote_mime_filename(Name) ->
    <<"\"", (escape_mime_quoted(Name))/binary, "\"">>.

%% RFC 2047 §2: an encoded-word is at most 75 characters including its
%% "=?UTF-8?B?" prefix and "?=" suffix, which leaves 63 base64 characters, i.e.
%% 45 source bytes per word.
-define(ENCODED_WORD_MAX_BYTES, 45).

-doc false.
%% `Value` as one or more RFC 2047 base64 encoded-words joined by a space. Each
%% word stays within the 75-character limit and is split only on character
%% boundaries, so no word carries half of a multi-byte character.
-spec encoded_words(binary()) -> binary().
encoded_words(Value) ->
    Chunks = chunk(unicode:characters_to_list(Value), [], <<>>),
    iolist_to_binary(
        lists:join(<<" ">>, [<<"=?UTF-8?B?", (base64:encode(C))/binary, "?=">> || C <- Chunks])
    ).

%% Split per code point, like the Python sibling.
chunk([], Acc, <<>>) ->
    lists:reverse(Acc);
chunk([], Acc, Cur) ->
    lists:reverse([Cur | Acc]);
chunk([Cp | Rest], Acc, Cur) ->
    Enc = <<Cp/utf8>>,
    case Cur =/= <<>> andalso byte_size(Cur) + byte_size(Enc) > ?ENCODED_WORD_MAX_BYTES of
        true -> chunk(Rest, [Cur | Acc], Enc);
        false -> chunk(Rest, Acc, <<Cur/binary, Enc/binary>>)
    end.

-doc false.
%% An RFC 5322 `name-addr` (`Name <addr>`) for vendors that take the sender as
%% one string.
%%
%% A non-ASCII name becomes encoded-words (RFC 2047 §5 forbids them inside a
%% quoted-string, and SES requires them for a Unicode "friendly from"); an
%% atext-only name is a bare phrase; anything else (a comma, dot, quote, …) is
%% a quoted-string, otherwise `Doe, Jane <a@b>` parses as two mailboxes.
%%
%% `Address` may already be `Name <addr>`: its own display name then wins over
%% `Name` (it is the per-message value) and is re-encoded, so the result never
%% nests angle brackets and a Unicode name is still encoded.
-spec format_mailbox(binary(), binary()) -> binary().
format_mailbox(Name, Address) ->
    Addr0 = strip_crlf(Address),
    Display0 = strip_crlf(Name),
    {Addr, Display} =
        case
            re:run(Addr0, "^(.*)<([^<>]*)>\\s*\\z", [
                dotall, unicode, {capture, all_but_first, binary}
            ])
        of
            {match, [Own0, Inner]} ->
                case unquote(string:trim(Own0)) of
                    <<>> -> {string:trim(Inner), Display0};
                    Own -> {string:trim(Inner), Own}
                end;
            nomatch ->
                {Addr0, Display0}
        end,
    case Display of
        <<>> ->
            Addr;
        _ ->
            Phrase =
                case is_ascii(Display) of
                    false ->
                        encoded_words(Display);
                    true ->
                        case re:run(Display, "^[A-Za-z0-9!#$%&'*+\\-/=?^_`{|}~ ]+\\z") of
                            {match, _} -> Display;
                            nomatch -> quoted_string(Display)
                        end
                end,
            <<Phrase/binary, " <", Addr/binary, ">">>
    end.

quoted_string(S) ->
    <<"\"", (escape_backslash_and_quote(S))/binary, "\"">>.

%% The text of a quoted-string display name (`"Doe, Jane"` -> `Doe, Jane`).
unquote(<<"\"", _/binary>> = P) when byte_size(P) >= 2 ->
    case binary:last(P) of
        $" ->
            Inner = binary:part(P, 1, byte_size(P) - 2),
            re:replace(Inner, "\\\\(.)", "\\1", [global, unicode, {return, binary}]);
        _ ->
            P
    end;
unquote(P) ->
    P.

is_ascii(B) -> lists:all(fun(C) -> C =< 16#7F end, binary_to_list(B)).

-doc false.
%% Display text for a value read from a vendor RESPONSE (an id, a code, an
%% errors map). Never fails: a crash after an accepted send would invite a
%% duplicate retry.
-spec response_text(term()) -> binary().
response_text(undefined) ->
    <<>>;
response_text(null) ->
    <<>>;
response_text(B) when is_binary(B) -> B;
response_text(true) ->
    <<"true">>;
response_text(false) ->
    <<"false">>;
response_text(I) when is_integer(I) -> integer_to_binary(I);
response_text(F) when is_float(F) -> float_text(F);
response_text(V) ->
    try
        %% The stock encoder typed to accept any term (see the json module).
        iolist_to_binary(json:encode(V, fun json:encode_value/2))
    catch
        _:_ -> <<>>
    end.

-doc false.
%% The first non-empty binary, else `<<>>`.
-spec first_non_empty([binary()]) -> binary().
first_non_empty([]) -> <<>>;
first_non_empty([<<>> | Rest]) -> first_non_empty(Rest);
first_non_empty([V | _]) -> V.

-doc false.
-spec bin(binary() | atom() | integer() | float() | string()) -> binary().
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(F) when is_float(F) -> float_text(F);
bin(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        B when is_binary(B) -> B;
        %% Not valid Unicode: the same badarg a non-character list raises.
        _ -> erlang:error(badarg, [L])
    end.

-doc false.
%% A string the way Python's `repr()` shows it in an error message (the
%% sibling's wording): single-quoted unless it holds a `'` and no `"`, with
%% backslash and control characters escaped.
-spec py_repr(binary()) -> binary().
py_repr(S) ->
    Q =
        case {binary:match(S, <<"'">>), binary:match(S, <<"\"">>)} of
            {nomatch, _} -> $';
            {_, nomatch} -> $";
            _ -> $'
        end,
    Body = [repr_char(C, Q) || <<C>> <= S],
    iolist_to_binary([Q, Body, Q]).

repr_char($\\, _) -> <<"\\\\">>;
repr_char($\n, _) -> <<"\\n">>;
repr_char($\r, _) -> <<"\\r">>;
repr_char($\t, _) -> <<"\\t">>;
repr_char(Q, Q) -> <<$\\, Q>>;
repr_char(C, _) when C < 16#20; C =:= 16#7F -> io_lib:format("\\x~2.16.0b", [C]);
repr_char(C, _) -> <<C>>.

-doc false.
%% Add an optional key only when there is a value: absent is an omitted key,
%% never `undefined`/`null`.
-spec put_opt(atom() | binary(), term(), map()) -> map().
put_opt(_K, undefined, M) -> M;
put_opt(K, V, M) -> M#{K => V}.

-doc false.
%% The normalized send result. Failures never get here: they `fail/1`.
-spec result(thinwrap_notifications:send_status(), binary(), term()) ->
    thinwrap_notifications:send_result().
result(Status, MessageId, Raw) ->
    #{success => true, status => Status, provider_message_id => MessageId, raw => Raw}.

-doc false.
%% Add a key only when the value is non-empty — the siblings' `if msg.field:`.
-spec put_nonempty(binary(), term(), map()) -> map().
put_nonempty(_K, undefined, M) -> M;
put_nonempty(_K, <<>>, M) -> M;
put_nonempty(_K, [], M) -> M;
put_nonempty(_K, V, M) when V =:= #{} -> M;
put_nonempty(K, V, M) -> M#{K => V}.

-doc false.
%% A non-credential config value; an absent optional key reads as `<<>>`, the
%% Python sibling's empty-string default.
-spec cfg(thinwrap_notifications:config(), atom()) -> binary().
cfg(Config, Key) ->
    case maps:get(Key, Config, <<>>) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end.
