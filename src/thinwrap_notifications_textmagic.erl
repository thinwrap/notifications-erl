-module(thinwrap_notifications_textmagic).
-moduledoc false.

%% Textmagic SMS connector (v2 form-encoded API, two-header auth).

-behaviour(thinwrap_notifications_provider).

-export([send/2]).

-define(ENDPOINT, <<"https://rest.textmagic.com/api/v2/messages">>).

-doc false.
-spec send(thinwrap_notifications:config(), map()) -> thinwrap_notifications:send_result().
send(Config, I) ->
    %% The recipient field is "phones" on the wire. Wire keys are camelCase and
    %% passthrough keys ride as given, flattened into the form.
    From = thinwrap_notifications_util:first_non_empty([
        maps:get(from, I), thinwrap_notifications_util:cfg(Config, from)
    ]),
    Fields = thinwrap_notifications_passthrough:merge_form(
        [{<<"text">>, maps:get(body, I)}, {<<"phones">>, maps:get(to, I)}] ++
            [{<<"from">>, From} || From =/= <<>>],
        I
    ),
    %% Auth is the two independent headers X-TM-Username and X-TM-Key (neither
    %% Basic nor Bearer).
    {_, Headers, _} = thinwrap_notifications_passthrough:merge(
        #{},
        #{
            <<"X-TM-Username">> => thinwrap_notifications_util:cfg(Config, username),
            <<"X-TM-Key">> => thinwrap_notifications_input:secret(Config, api_key)
        },
        [],
        I
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_notifications_http:send_post_form(Config, ?ENDPOINT, Fields, Headers, []),
    Raw = thinwrap_notifications_json:decode(RB),
    thinwrap_notifications_util:ok_status(Status) orelse fail_response(Status, RH, Raw),
    %% Some endpoints return messageId instead of id; both are numeric.
    Id =
        case thinwrap_notifications_json:get(Raw, <<"id">>) of
            undefined ->
                thinwrap_notifications_util:response_text(
                    thinwrap_notifications_json:get(Raw, <<"messageId">>)
                );
            V ->
                thinwrap_notifications_util:response_text(V)
        end,
    thinwrap_notifications_util:result(sent, Id, Raw).

%% Raise the mapped error for a non-2xx response.
-spec fail_response(integer(), map(), term()) -> no_return().
fail_response(Status, RH, Raw) ->
    %% Body shape: {message,code}; a 422 is treated as an invalid
    %% recipient.
    Msg =
        case
            thinwrap_notifications_json:str(
                thinwrap_notifications_json:get(Raw, <<"message">>)
            )
        of
            <<>> ->
                Base = <<"Textmagic HTTP ", (integer_to_binary(Status))/binary>>,
                case
                    thinwrap_notifications_util:response_text(
                        thinwrap_notifications_json:get(Raw, <<"code">>)
                    )
                of
                    <<>> -> Base;
                    C -> <<Base/binary, " ", C/binary>>
                end;
            M ->
                M
        end,
    thinwrap_notifications_error:fail(
        thinwrap_notifications_error:vendor_error(Status, RH, Raw, map_code(Status), Msg)
    ).

map_code(S) when S =:= 401; S =:= 403 -> auth_failed;
map_code(429) -> rate_limited;
map_code(422) -> invalid_recipient;
map_code(S) when S >= 500 -> provider_unavailable;
map_code(S) when S >= 400 -> invalid_request;
map_code(_) -> unknown.
