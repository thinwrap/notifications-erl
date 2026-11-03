-module(thinwrap_notifications_sns).
-moduledoc false.

%% AWS SNS SMS connector (SigV4-signed AWS Query Publish API; XML response).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(FORM, <<"application/x-www-form-urlencoded">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    %% SNS's AWS Query keys are verbatim (indexed attribute keys like
    %% "MessageAttributes.entry.1.Name" are not simple-case transformable), so
    %% no casing transform is applied to the passthrough body.
    To = maps:get(to, I),
    HasTopic =
        not lists:member(
            maps:get(<<"TopicArn">>, thinwrap_notifications_passthrough:body(I), null), [
                null, undefined
            ]
        ),
    (To =/= <<>> orelse HasTopic) orelse
        thinwrap_notifications_error:fail(
            thinwrap_notifications_error:invalid_request(
                <<"SNS requires either `to` (phone E.164) or a `TopicArn` passthrough field.">>
            )
        ),
    Fields = thinwrap_notifications_passthrough:merge_form(
        [
            {<<"Action">>, <<"Publish">>},
            {<<"Version">>, <<"2010-03-31">>},
            {<<"Message">>, maps:get(body, I)}
        ] ++ [{<<"PhoneNumber">>, To} || To =/= <<>>],
        I
    ),
    {_, Headers, Query} = thinwrap_notifications_passthrough:merge(
        #{}, #{<<"Content-Type">> => ?FORM}, [], I
    ),
    %% Serialize the merged body ONCE; the exact bytes are both signed (the
    %% payload hash) and transmitted, so the body and the signature agree.
    Payload = thinwrap_notifications_util:encode_form(Fields),
    Region = thinwrap_notifications_util:cfg(Config, region),
    ok = thinwrap_notifications_sigv4:validate_region(Region, <<"SNS">>),
    Host = <<"sns.", Region/binary, ".amazonaws.com">>,
    %% Any passthrough query is folded (sorted, RFC 3986-encoded) into the
    %% signed canonical query string AND the request URL identically, else
    %% SignatureDoesNotMatch.
    CanonicalQuery = thinwrap_notifications_sigv4:build_canonical_query(Query),
    Endpoint =
        case CanonicalQuery of
            <<>> -> <<"https://", Host/binary, "/">>;
            _ -> <<"https://", Host/binary, "/?", CanonicalQuery/binary>>
        end,
    Signed = thinwrap_notifications_sigv4:sign(#{
        method => <<"POST">>,
        service => <<"sns">>,
        region => Region,
        host => Host,
        path => <<"/">>,
        payload => Payload,
        access_key_id => thinwrap_notifications_input:secret(Config, access_key_id),
        secret_access_key => thinwrap_notifications_input:secret(Config, secret_access_key),
        session_token => thinwrap_notifications_input:secret(Config, session_token),
        canonical_query => CanonicalQuery,
        signed => Headers
    }),
    %% Signed values win on collision — Host/X-Amz-Date/Authorization are not
    %% caller-overridable.
    ReqHeaders = thinwrap_notifications_sigv4:with_signed_headers(Headers, Signed),
    #{status := Status, headers := RH, body := Xml} =
        thinwrap_notifications_http:send_post_raw(Config, Endpoint, ?FORM, Payload, ReqHeaders, []),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Xml),
    thinwrap_notifications_util:result(sent, xml_tag(Xml, <<"MessageId">>), Xml).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), binary()) -> no_return().
fail_response(Status, RH, Xml) ->
    Code = xml_tag(Xml, <<"Code">>),
    Msg = thinwrap_notifications_util:first_non_empty([
        xml_tag(Xml, <<"Message">>), <<"SNS HTTP ", (integer_to_binary(Status))/binary>>
    ]),
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(
            Status, RH, Xml, map_code(Status, Code), Msg
        )
    ).

%% Text content of the first <Tag>...</Tag> element in the (untrusted) XML,
%% or <<>> when absent. A flat-tag extractor is enough for the
%% <Code>/<Message>/<MessageId> tags SNS returns.
xml_tag(Xml, Tag) ->
    Open = <<"<", Tag/binary, ">">>,
    case binary:match(Xml, Open) of
        nomatch ->
            <<>>;
        {I, L} ->
            Start = I + L,
            Rest = binary:part(Xml, Start, byte_size(Xml) - Start),
            case binary:match(Rest, <<"</", Tag/binary, ">">>) of
                nomatch -> <<>>;
                {J, _} -> binary:part(Rest, 0, J)
            end
    end.

%% HTTP-layer first, then the XML <Code> value disambiguates within 4xx.
map_code(S, C) when
    C =:= <<"InvalidClientTokenId">>; C =:= <<"SignatureDoesNotMatch">>; S =:= 401; S =:= 403
->
    auth_failed;
map_code(S, C) when C =:= <<"Throttling">>; C =:= <<"ThrottlingException">>; S =:= 429 ->
    rate_limited;
map_code(S, _) when S >= 500 -> provider_unavailable;
map_code(S, _) when S >= 400 -> invalid_request;
map_code(_, C) when C =:= <<"InvalidParameter">>; C =:= <<"InvalidParameterValue">> ->
    invalid_request;
map_code(_, _) ->
    unknown.
