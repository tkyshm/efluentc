%%%-------------------------------------------------------------------
%% @doc efluentc top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(efluentc_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% API functions
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% Supervisor callbacks
init([]) ->
    SupFlags = #{
      strategy  => one_for_all,
      intensity => 1000,
      period    => 3600
     },

    ClientSup = #{
      id       => 'efluentc_client_sup',
      start    => {'efluentc_client_sup', start_link, []},
      restart  => permanent,
      shutdown => 2000,
      type     => supervisor,
      modules  => ['efluentc_client_sup']
    },

    {ok, {SupFlags, [ClientSup]}}.
