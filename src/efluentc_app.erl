%%%-------------------------------------------------------------------
%% @doc efluentc public API
%% @end
%%%-------------------------------------------------------------------

-module(efluentc_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% API

start(_StartType, _StartArgs) ->
    ets:new(efluentc, [public, set, named_table]),
    efluentc_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.
