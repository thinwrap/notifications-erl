-module(thinwrap_notifications_mailgun).
-moduledoc false.

%% Mailgun email connector (form-encoded / multipart Messages API, Basic auth).
%%
%% Without attachments the body is application/x-www-form-urlencoded, with
%% attachments multipart/form-data. Returns `queued`: Mailgun's response is
%% queue acceptance, not delivery. Mailgun-specific per-send fields ride
%% verbatim in passthrough body (its wire keys are literal: o:tag,
%% o:deliverytime, o:tracking, v:<name>, template, t:variables) — no casing
%% transform.

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

%% Mailgun accepts up to 3 o:tag fields; extra tags are dropped (graceful
%% degradation per the >=90% baseline-coverage rule).
-define(MAX_TAGS, 3).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    BaseUrl =
        case thinwrap_notifications_util:cfg(Config, base_url) of
            <<>> ->
                case thinwrap_notifications_util:cfg(Config, region) of
                    <<"eu">> -> <<"https://api.eu.mailgun.net">>;
                    _ -> <<"https://api.mailgun.net">>
                end;
            Url ->
                %% The Basic credential rides on every request; over http:// it
                %% would cross the network in cleartext.
                case string:prefix(string:lowercase(Url), <<"https://">>) of
                    nomatch ->
                        thinwrap_notifications_error:fail(
                            thinwrap_notifications_error:invalid_request(
                                <<"Mailgun base_url must be an https:// URL.">>
                            )
                        );
                    _ ->
                        Url
                end
        end,
    Endpoint =
        <<BaseUrl/binary, "/v3/",
            (thinwrap_notifications_util:quote(
                thinwrap_notifications_util:cfg(Config, domain), <<>>
            ))/binary,
            "/messages">>,
    User = thinwrap_notifications_util:first_non_empty([
        thinwrap_notifications_util:cfg(Config, username), <<"api">>
    ]),
    Auth = thinwrap_notifications_util:basic_auth(
        User, thinwrap_notifications_input:secret(Config, api_key)
    ),
    Fields = thinwrap_notifications_passthrough:merge_form(build_fields(Config, I), I),
    {_, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{}, #{<<"Authorization">> => Auth}, [], I
    ),
    Tags = lists:sublist(maps:get(tags, I), ?MAX_TAGS),
    #{status := Status, headers := RH, body := RB} =
        case maps:get(attachments, I) of
            [] ->
                thinwrap_notifications_http:send_post_form(
                    Config, Endpoint, with_tags(Fields, Tags), Headers, []
                );
            Attachments ->
                {Content, Boundary} = multipart(Fields, Attachments, Tags),
                thinwrap_notifications_http:send_post_raw(
                    Config,
                    Endpoint,
                    <<"multipart/form-data; boundary=", Boundary/binary>>,
                    Content,
                    Headers,
                    []
                )
        end,
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    thinwrap_notifications_util:result(
        queued, thinwrap_notifications_json:str(thinwrap_notifications_json:get(Raw, <<"id">>)), Raw
    ).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    Msg = thinwrap_notifications_json:str(
        thinwrap_notifications_json:get(Raw, <<"message">>)
    ),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Raw, map_code(Status, Msg), Msg
        )
    ).

%% Hand-maps the input onto Mailgun's form fields (reply_to -> h:Reply-To,
%% custom headers -> h:<Name>), in a stable order. o:tag is added at
%% serialization time as a repeated field.
build_fields(Config, I) ->
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    Base =
        [
            {<<"from">>,
                thinwrap_notifications_util:format_mailbox(
                    thinwrap_notifications_util:cfg(Config, sender_name), From
                )},
            {<<"to">>, maps:get(to, I)},
            {<<"subject">>, maps:get(subject, I)}
        ] ++
            [{<<"html">>, V} || V <- [maps:get(html, I)], V =/= <<>>] ++
            [{<<"text">>, V} || V <- [maps:get(text, I)], V =/= <<>>] ++
            [{<<"cc">>, join(L)} || L <- [maps:get(cc, I)], L =/= []] ++
            [{<<"bcc">>, join(L)} || L <- [maps:get(bcc, I)], L =/= []],
    %% Header names are case-insensitive, so `reply-to` and `Reply-To` would be
    %% two h: fields for one header. One entry per name: the later header wins
    %% (in name order — a map has no insertion order), and the typed reply_to
    %% wins over any Reply-To in headers.
    ByName0 = lists:foldl(
        fun({Name, Value}, Acc) -> put_ordered(string:lowercase(Name), {Name, Value}, Acc) end,
        [],
        lists:sort(maps:to_list(maps:get(headers, I)))
    ),
    ByName =
        case maps:get(reply_to, I) of
            <<>> -> ByName0;
            R -> put_ordered(<<"reply-to">>, {<<"Reply-To">>, R}, ByName0)
        end,
    Base ++ [{<<"h:", Name/binary>>, Value} || {_, {Name, Value}} <- ByName].

%% Replace in place (keeping the first position, like a dict re-assignment),
%% else append.
put_ordered(K, V, L) ->
    case lists:keymember(K, 1, L) of
        true -> lists:keyreplace(K, 1, L, {K, V});
        false -> L ++ [{K, V}]
    end.

join(L) -> iolist_to_binary(lists:join(<<",">>, L)).

%% The form path: the truncated tags extend any o:tag the passthrough set.
with_tags(Fields, []) ->
    Fields;
with_tags(Fields, Tags) ->
    Existing =
        case lists:keyfind(<<"o:tag">>, 1, Fields) of
            {_, L} when is_list(L) -> L;
            {_, null} -> [];
            {_, V} -> [V];
            false -> []
        end,
    put_ordered(<<"o:tag">>, Existing ++ Tags, Fields).

%% A multipart/form-data body from the form fields, the (already-truncated)
%% tags and the attachments. Each attachment is a name="attachment" part, or
%% name="inline" when it has a content_id.
multipart(Fields, Attachments, Tags) ->
    Boundary =
        <<"----=_Part_", (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary>>,
    Dash = <<"--", Boundary/binary>>,
    FieldParts = [
        field_part(Dash, K, Item)
     || {K, V} <- Fields,
        V =/= null,
        V =/= undefined,
        %% A list is a repeated field (o:tag, several v: values), as on the
        %% form-encoded path; a map becomes JSON via stringify_form.
        Item <- items(V)
    ],
    TagParts = [tag_part(Dash, T) || T <- Tags],
    AttParts = [attachment_part(Dash, A) || A <- Attachments],
    Body = iolist_to_binary([FieldParts, TagParts, AttParts, Dash, <<"--\r\n">>]),
    {Body, Boundary}.

field_part(Dash, K, Item) ->
    Value = thinwrap_notifications_util:stringify_form(Item),
    ok = thinwrap_notifications_util:assert_utf8(Value),
    %% Field names include caller-supplied custom-header keys (h:<Name>);
    %% sanitized so a CRLF or quote cannot break out of name="...".
    [
        Dash,
        <<"\r\nContent-Disposition: form-data; name=\"">>,
        thinwrap_notifications_util:escape_mime_quoted(K),
        <<"\"\r\n\r\n">>,
        Value,
        <<"\r\n">>
    ].

tag_part(Dash, T) ->
    ok = thinwrap_notifications_util:assert_utf8(T),
    [Dash, <<"\r\nContent-Disposition: form-data; name=\"o:tag\"\r\n\r\n">>, T, <<"\r\n">>].

attachment_part(Dash, #{filename := F, content := C, content_type := CT, content_id := Cid}) ->
    %% Mailgun takes an inline image's Content-ID from the part's
    %% filename, so the HTML's cid:<content_id> resolves only if the
    %% filename IS the content id.
    Filename = thinwrap_notifications_util:quote_mime_filename(
        thinwrap_notifications_util:first_non_empty([Cid, F])
    ),
    ContentType = thinwrap_notifications_util:strip_crlf(
        thinwrap_notifications_util:first_non_empty([CT, <<"application/octet-stream">>])
    ),
    FieldName =
        case Cid of
            <<>> -> <<"attachment">>;
            _ -> <<"inline">>
        end,
    [
        Dash,
        <<"\r\nContent-Disposition: form-data; name=\"">>,
        FieldName,
        <<"\"; filename=">>,
        Filename,
        <<"\r\nContent-Type: ">>,
        ContentType,
        <<"\r\n\r\n">>,
        C,
        <<"\r\n">>
    ].

items(L) when is_list(L) -> L;
items(V) -> [V].

%% The Mailgun (HTTP status, message) truth table. Mailgun returns flat error
%% bodies with the reason as `message`; a malformed recipient is told apart by
%% the message text.
%% 403: "Valid credentials but access denied" (Mailgun API overview).
map_code(S, _) when S =:= 401; S =:= 402; S =:= 403 -> auth_failed;
map_code(429, _) ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(400, Msg) ->
    case
        re:run(Msg, "not a valid email|invalid recipient|invalid address", [
            caseless, unicode, {capture, none}
        ])
    of
        match -> invalid_recipient;
        nomatch -> invalid_request
    end;
map_code(S, _) when S =:= 404; S =:= 413 -> invalid_request;
map_code(_, _) ->
    unknown.
