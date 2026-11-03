-module(thinwrap_notifications_http).
-moduledoc false.

%% The shared HTTP seam every connector sends through: builds the request,
%% rejects what an HTTP client would refuse (a header with a control
%% character, a URL with whitespace or a bad port) as `invalid_request` before
%% the transport is called, calls the configured transport, and normalizes a
%% transport failure. No JSON parsing, no error mapping, no casing — those
%% stay in each provider module.

-export([send_get/4, send_post_json/5, send_post_form/5, send_post_raw/6, merge_headers/2]).
-export_type([response/0, query/0, raw_headers/0]).

-type response() :: thinwrap_notifications_transport:response().
-type query() :: thinwrap_notifications_util:query().
%% Header maps as connectors and passthrough build them, before validation.
-type raw_headers() :: #{binary() | atom() => term()}.

-doc false.
-spec send_get(thinwrap_notifications:config(), binary(), raw_headers(), query()) -> response().
send_get(Config, Url, Headers, Query) ->
    invoke(
        Config,
        get,
        thinwrap_notifications_util:build_url(Url, Query),
        undefined,
        undefined,
        Headers
    ).

-doc false.
-spec send_post_json(thinwrap_notifications:config(), binary(), term(), raw_headers(), query()) ->
    response().
send_post_json(Config, Url, Body, Headers, Query) ->
    Data = thinwrap_notifications_json:encode(Body),
    invoke(
        Config,
        post,
        thinwrap_notifications_util:build_url(Url, Query),
        Data,
        <<"application/json">>,
        Headers
    ).

-doc false.
%% POST an `application/x-www-form-urlencoded` body; see
%% `thinwrap_notifications_util:encode_form/1` for list and null values.
-spec send_post_form(
    thinwrap_notifications:config(), binary(), [{binary(), term()}], raw_headers(), query()
) -> response().
send_post_form(Config, Url, Form, Headers, Query) ->
    Data = thinwrap_notifications_util:encode_form(Form),
    invoke(
        Config,
        post,
        thinwrap_notifications_util:build_url(Url, Query),
        Data,
        <<"application/x-www-form-urlencoded">>,
        Headers
    ).

-doc false.
%% POST caller-serialized bytes with an explicit content type (a SigV4-signed
%% body whose exact bytes must match the signature, a multipart body).
-spec send_post_raw(
    thinwrap_notifications:config(), binary(), binary(), binary(), raw_headers(), query()
) -> response().
send_post_raw(Config, Url, ContentType, Body, Headers, Query) ->
    invoke(
        Config, post, thinwrap_notifications_util:build_url(Url, Query), Body, ContentType, Headers
    ).

-doc false.
%% Overlay `Override` onto `Base` with HTTP's case-insensitive name rule
%% (RFC 9110 §5.1): a caller `content-type` replaces the connector's
%% `Content-Type` instead of travelling next to it (on SigV4 connectors two
%% would also break the signature). The override's spelling is the one sent.
%% Values are kept as given; `checked/1` validates them.
-spec merge_headers(raw_headers(), raw_headers()) -> raw_headers().
merge_headers(Base, Override) ->
    maps:fold(
        fun(Name0, Value, Acc) ->
            Name = header_name(Name0),
            Lower = lower(Name),
            Kept = maps:filter(fun(K, _) -> lower(header_name(K)) =/= Lower end, Acc),
            Kept#{Name => Value}
        end,
        Base,
        Override
    ).

header_name(A) when is_atom(A) -> atom_to_binary(A);
header_name(N) -> N.

lower(B) when is_binary(B) -> string:lowercase(B);
lower(Other) -> Other.

invoke(Config, Method, Url, Body, ContentType, Headers0) ->
    check_url(Url),
    CT =
        case ContentType of
            undefined -> #{};
            _ -> #{<<"Content-Type">> => ContentType}
        end,
    Headers = checked(merge_headers(CT, Headers0)),
    Req0 = #{method => Method, url => Url, headers => Headers},
    Req =
        case Body of
            undefined -> Req0;
            _ -> Req0#{body => Body}
        end,
    {Mod, Opts} = maps:get(transport, Config),
    Result =
        try
            Mod:request(Req, Opts)
        catch
            throw:{thinwrap_notifications_error, _} = Thrown ->
                throw(Thrown);
            Class:Reason ->
                {error, {Class, Reason}}
        end,
    case Result of
        {ok, #{status := S, headers := H, body := B} = Resp} when
            is_integer(S), is_map(H), is_binary(B)
        ->
            Resp;
        {error, {connector_error, #{code := _} = E}} ->
            thinwrap_notifications_error:fail(E);
        {error, Reason2} ->
            thinwrap_notifications_error:fail(transport_failure(Reason2));
        Other ->
            %% A transport that breaks its contract is a bug in the calling
            %% code, not a provider outage — report it as such.
            erlang:error({bad_transport_return, Mod, shape(Other)})
    end.

shape({ok, M}) when is_map(M) -> {ok, maps:keys(M)};
shape(T) when is_tuple(T) -> {tuple, tuple_size(T)};
shape(T) when is_atom(T) -> T;
shape(_) -> other.

%% Only the kind of failure ever leaves this function — never the reason term.
%% A client's error may embed the full request URL, which for Telegram
%% (`/bot<token>/`) and every chat webhook IS the credential.
transport_failure(Reason) ->
    Kind = kind(Reason),
    Msg = <<"Upstream transport error (", Kind/binary, ")">>,
    thinwrap_notifications_error:new(provider_unavailable, #{
        message => Msg,
        provider_message => Msg,
        cause => #{<<"raw">> => #{<<"exception">> => Kind}}
    }).

%% The leading atom of the reason: `timeout`, `failed_connect`, `econnrefused`,
%% or, for a crashing transport (`{Class, Reason}`), the crash reason's own.
kind({Class, Reason}) when Class =:= error; Class =:= exit; Class =:= throw ->
    kind(Reason);
kind(A) when is_atom(A) -> atom_to_binary(A);
kind(T) when is_tuple(T), tuple_size(T) > 0, is_atom(element(1, T)) ->
    atom_to_binary(element(1, T));
kind(_) ->
    <<"transport_error">>.

%% http clients refuse whitespace, controls and non-ASCII in the request
%% target, and an unparseable port, before connecting; that would otherwise
%% surface as a retryable outage for what is a request (often config) error.
%% The URL is never echoed: it may carry a token.
check_url(Url) ->
    case re:run(Url, "[^\\x21-\\x7e]", [{capture, none}]) of
        match ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:invalid_request(
                    <<
                        "The request URL contains whitespace, a control character "
                        "or a non-ASCII character."
                    >>
                )
            );
        nomatch ->
            ok
    end,
    case valid_port(Url) of
        true ->
            ok;
        false ->
            thinwrap_notifications_error:fail(
                thinwrap_notifications_error:invalid_request(
                    <<"The request URL has an invalid port.">>
                )
            )
    end.

%% The port the way Python's `urlsplit().port` reads it: after the userinfo,
%% the text after the first `:` (or after `]:` for an IPv6 literal); empty is
%% "no port"; otherwise digits in 0..65535.
valid_port(Url) ->
    Rest =
        case binary:match(Url, <<"://">>) of
            {P, 3} -> binary:part(Url, P + 3, byte_size(Url) - P - 3);
            nomatch -> Url
        end,
    Authority = hd(binary:split(Rest, [<<"/">>, <<"?">>, <<"#">>])),
    HostInfo = lists:last(binary:split(Authority, <<"@">>, [global])),
    Port =
        case HostInfo of
            <<"[", _/binary>> ->
                case binary:split(HostInfo, <<"]">>) of
                    [_, <<":", Pt/binary>>] -> Pt;
                    _ -> <<>>
                end;
            _ ->
                case binary:split(HostInfo, <<":">>) of
                    [_, Pt] -> Pt;
                    [_] -> <<>>
                end
        end,
    case Port of
        <<>> ->
            true;
        _ ->
            case re:run(Port, "^[0-9]+\\z", [{capture, none}]) of
                match -> binary_to_integer(Port) =< 65535;
                nomatch -> false
            end
    end.

%% Validate and stringify outgoing headers. Names the offending header but
%% never echoes its value, which is usually a credential.
checked(Headers) ->
    maps:fold(
        fun(Name, Value, Acc) ->
            check_name(Name),
            Text = header_value(Name, Value),
            case re:run(Text, "[\\x00-\\x08\\x0a-\\x1f\\x7f]", [{capture, none}]) of
                match ->
                    bad_header(
                        <<"Header ", Name/binary, " contains a line break or control character.">>
                    );
                nomatch ->
                    ok
            end,
            %% Header values go on the wire as Latin-1.
            latin1_safe(Text) orelse
                bad_header(
                    <<"Header ", Name/binary,
                        " contains characters that cannot be sent in an HTTP header.">>
                ),
            Acc#{Name => Text}
        end,
        #{},
        Headers
    ).

%% RFC 9110 token.
check_name(Name) when is_binary(Name), Name =/= <<>> ->
    case re:run(Name, "^[!#$%&'*+.^_`|~0-9A-Za-z-]+\\z", [{capture, none}]) of
        match -> ok;
        nomatch -> bad_name()
    end;
check_name(_) ->
    bad_name().

-spec bad_name() -> no_return().
bad_name() ->
    bad_header(
        <<"A header name is empty or contains a character not allowed in an HTTP header name.">>
    ).

header_value(_Name, true) -> <<"true">>;
header_value(_Name, false) -> <<"false">>;
header_value(_Name, B) when is_binary(B) -> B;
header_value(_Name, I) when is_integer(I) -> integer_to_binary(I);
header_value(_Name, F) when is_float(F) -> float_to_binary(F, [short]);
header_value(Name, _) -> bad_header(<<"Header ", Name/binary, " must be a string or number.">>).

latin1_safe(Text) ->
    case unicode:characters_to_list(Text) of
        L when is_list(L) -> lists:all(fun(C) -> C =< 16#FF end, L);
        _ -> false
    end.

-spec bad_header(binary()) -> no_return().
bad_header(Msg) ->
    thinwrap_notifications_error:fail(thinwrap_notifications_error:invalid_request(Msg)).
