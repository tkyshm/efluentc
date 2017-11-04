%%%-------------------------------------------------------------------
%%% @author tkyshm
%%% @copyright (C) 2017, tkyshm
%%% @doc
%%%
%%% @end
%%% Created : 2017-11-01 22:19:56.691384
%%%-------------------------------------------------------------------
-module(efluentc_client_sup).

-behaviour(supervisor).

-include("efluentc.hrl").

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%% API functions
%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    Num = application:get_env(efluentc, worker_size, ?DEFAULT_WORKER_SIZE),
    Ret = supervisor:start_link({local, ?SERVER}, ?MODULE, []),
    [supervisor:start_child(?SERVER, [Id]) || Id <- lists:seq(0, Num-1)],
    Ret.

%%% Supervisor callbacks
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    SupFlags = #{
      strategy  => simple_one_for_one,
      intensity => 1000,
      period    => 3600
    },

    Child = #{
      id       => 'efluentc_client',
      start    => {'efluentc_client', start_link, []},
      restart  => permanent,
      shutdown => 2000,
      type     => worker,
      modules  => ['efluentc_client']
    },

    {ok, {SupFlags, [Child]}}.
