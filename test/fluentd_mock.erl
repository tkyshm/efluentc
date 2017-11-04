-module(fluentd_mock).

-export([start_link/1, stop/0]).

-include_lib("common_test/include/ct.hrl").

start_link(Checker) ->
    Pid = spawn_link(fun() -> init(Checker) end),
    erlang:register(fluentd_mock, Pid),
    Pid.

stop() ->
    exit(whereis(fluentd_mock), ok).

init(Checker) ->
    {ok, LS} = gen_tcp:listen(24224, [binary,
                                      {packet, 0},
                                      {active, false},
                                      {reuseaddr, true}]),


    process_flag(trap_exit, true),

    % default efluentc worker is 2
    Pids = [spawn(fun() -> accept(Checker, LS) end)|| _ <- lists:seq(1, 2)],

    receive
        {'EXIT', _Pid, _Reason} ->
            [exit(P, ok) || P <- Pids],
            gen_tcp:close(LS)
    end.


accept(Checker, LS) ->
    case gen_tcp:accept(LS) of
        {ok, Sock} ->
            %spawn(fun() -> accept(Checker, LS) end),
            loop(Checker, Sock);
        {error, closed} ->
            closed
    end.

loop(Checker, Sock) ->
    process_flag(trap_exit, true),
    ok = gen_tcp:controlling_process(Sock, self()),
    inet:setopts(Sock, [{active, once}]),
    receive
        {tcp, Sock, Bin} ->
            Checker ! {ok, Bin},
            loop(Checker, Sock);
        {tcp_closed, Sock} ->
            gen_tcp:close(Sock);
        {tcp_error, Sock, Reason} ->
            Checker ! {error, Reason},
            loop(Checker, Sock);
        {'EXIT', _Pid, _Reason} ->
            gen_tcp:close(Sock)
    end.
