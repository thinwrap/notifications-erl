-module(thinwrap_notifications_provider).
-moduledoc false.

%% The contract every provider module (`thinwrap_notifications_<provider>`)
%% implements. `Config` and `Input` arrive validated and defaulted by
%% `thinwrap_notifications_input`; `send/2` returns the normalized result or
%% aborts with `thinwrap_notifications_error:fail/1`, which the public module
%% turns into `{error, ConnectorError}`.

-callback send(
    Config :: thinwrap_notifications:config(),
    Input :: map()
) -> thinwrap_notifications:send_result().
