%%%-------------------------------------------------------------------
%%% @author tkyshm
%%% @copyright (C) 2017, tkyshm
%%% @doc
%%% efluentc is the fluentd client
%%% @end
%%% Created : 2017-11-01 21:35:19.275127
%%%-------------------------------------------------------------------
-module(efluentc).

-include("efluentc.hrl").

-export([post/2]).

-type message() :: binary() | string().
-type tag() :: binary() | atom() | map().

%% @doc
%% post message to fluentd.
%% @end
-spec post(Tag :: tag(), Msg :: message()) -> ok.
post(Tag, Msg)  ->
    Pid = fetch_client(),
    gen_statem:cast(Pid, {post, Tag, Msg}).

%% @private
-spec fetch_client() -> pid().
fetch_client() ->
    Num = application:get_env(efluentc, worker_size, ?DEFAULT_WORKER_SIZE),
    Key = erlang:system_time(nano_seconds) rem Num,
    [{Key, Pid}] = ets:lookup(efluentc, Key),
    Pid.
