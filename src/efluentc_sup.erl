%%%-------------------------------------------------------------------
%% @doc efluentc top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(efluentc_sup).

-behaviour(supervisor).

-include("efluentc.hrl").

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% API functions
start_link() ->
    Num = application:get_env(efluentc, worker_size, ?DEFAULT_WORKER_SIZE),
    Ret = supervisor:start_link({local, ?SERVER}, ?MODULE, []),
    [supervisor:start_child(?SERVER, [Id]) || Id <- lists:seq(0, Num-1)],
    Ret.

%% Supervisor callbacks
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
