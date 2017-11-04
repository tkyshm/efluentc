%%%-------------------------------------------------------------------
%%% @author tkyshm
%%% @copyright (C) 2017, tkyshm
%%% @doc
%%%
%%% @end
%%% Created : 2017-11-01 21:35:19.275127
%%%-------------------------------------------------------------------
-module(efluentc_client).

-behaviour(gen_statem).

%% API
-export([start_link/1]).

%% gen_statem callbacks
-export([
         init/1,
         callback_mode/0,
         format_status/2,
         buffered/3,
         closed/3,
         empty/3,
         handle_event/4,
         terminate/3,
         code_change/4
        ]).

-define(SERVER, ?MODULE).

-define(DEFAULT_FLUSH_TIMEOUT, 50). % default 50 msec
-define(DEFAULT_FLUSH_BUFFER_SIZE, 1024 * 10). % defualt 10KB
-define(MAX_RETRY_COUNT, 3). % if post failed, 3 retry
-define(GEN_TCP_OPTS, [binary,
                       {packet, 0},
                       {active, false}]).

-define(BUFFER_CACHE_SIZE, 5).

-define(ERR_LOG(Fmt, Args), errlog(Fmt, Args, ?FILE, ?LINE)).
-define(INFO_LOG(Fmt, Args), infolog(Fmt, Args, ?FILE, ?LINE)).

-define(DATE_FORMAT, "~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w").
-define(LOG_FORMAT, "~ts [~ts] ~ts line ~B: ~p~n").

-record(state, {
    id                = 0         :: integer(),
    host              = localhost :: atom() | inet:ip_address(),
    port              = 0         :: integer(),
    buffer            = <<>>      :: binary(),
    buffer_caches     = []        :: [binary()], % cached buffers when state is closed.
    flush_buffer_size = 0         :: integer(),
    flush_timeout     = 1000      :: integer(),
    sock              = undefined :: inet:sock(),
    tries             = 0         :: integer()
}).

-type client_state() :: #state{}.

%%% API
%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link(Id) -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Id) ->
    {ok, Pid} = gen_statem:start_link(?MODULE, [Id], []),
    ets:insert(efluentc, {Id, Pid}),
    {ok, Pid}.

%%% gen_statem callbacks
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_statem is started using gen_statem:start/[3,4] or
%% gen_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {CallbackMode, StateName, State} |
%%                     {CallbackMode, StateName, State, Actions} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([Id]) ->
    Host = application:get_env(efluentc, host, localhost),
    Port = application:get_env(efluentc, port, 24224),
    BuffSize = application:get_env(efluentc, flush_buffer_size, ?DEFAULT_FLUSH_BUFFER_SIZE),
    Timeout = application:get_env(efluentc, flush_timeout, ?DEFAULT_FLUSH_TIMEOUT),
    State = #state{id = Id,
                   host = Host,
                   port = Port,
                   flush_buffer_size = BuffSize,
                   flush_timeout = Timeout},
    process_flag(trap_exit, true),
    {ok, closed, State, [{next_event, cast, connect}]}.

callback_mode() -> state_functions.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Called (1) whenever sys:get_status/1,2 is called by gen_statem or
%% (2) when gen_statem terminates abnormally.
%% This callback is optional.
%% @end
%%--------------------------------------------------------------------
format_status(Opt, [_PDict, State, Data]) ->
    SD = {State, [{id, Data#state.id},
                  {host, Data#state.host},
                  {port, Data#state.port},
                  {tries, Data#state.tries},
                  {buffer_size, byte_size(Data#state.buffer)},
                  {buffer_caches_size, length(Data#state.buffer_caches)},
                  {flush_buffer_size, Data#state.flush_buffer_size},
                  {flush_timeout, Data#state.flush_timeout}]},

    case Opt of
        terminate ->
            SD;
        normal ->
            [{data, [{"State", SD}]}]
    end.


%% @private
%% @doc
%% Closed state also can be recieved any messages, but theses messages
%% cached in process state record. And when the process established
%% connection to fluentd, it flush cached all messages.
%% Cached size limit is BUFFER_CACHE_SIZE * flush_cache_size,
%% so we can adjust it with flush_cache_size.
%%
%% If process failed to establish connection, do continue to reconnect
%% by exponential backoff.
%% @end
closed({timeout, connect}, {reconnect, N}, State) ->
    case try_connect(State) of
        {ok, NewState, empty} ->
            ?INFO_LOG("reconnect success", []),
            {next_state, empty, NewState};
        {ok, NewState, buffered} ->
            ?INFO_LOG("reconnect success", []),
            {next_state, buffered, NewState, flush_action()};
        {error, Reason} ->
            ?ERR_LOG("connect failed: ~p", [Reason]),
            {next_state, closed, State, reconnect_action(N+1)}
    end;
closed(cast, connect, State) ->
    case try_connect(State) of
        {ok, NewState, empty} ->
            {next_state, empty, NewState};
        {ok, NewState, buffered} ->
            {next_state, bufferd, NewState, flush_action()};
        {error, Reason} ->
            ?ERR_LOG("connect failed: ~p", [Reason]),
            {next_state, closed, State, reconnect_action(0)}
    end;
closed(cast,
       {post, Tag, Data},
       #state{buffer = Buffs, buffer_caches = Caches, flush_buffer_size = FBS} = State)
  when FBS < byte_size(Buffs) ->
    Msg = encode_msg(Tag, Data),
    NewCaches = append_buffer_caches(Buffs, Caches),
    {next_state, closed, State#state{buffer = Msg, buffer_caches = NewCaches}};
closed(cast, {post, Tag, Data}, #state{buffer = Buffs} = State) ->
    Msg = encode_msg(Tag, Data),
    NewBuffs = <<Buffs/binary, Msg/binary>>,
    {next_state, closed, State#state{buffer = NewBuffs}}.

%% @private
%% @doc
%% Empty state is ready to send messages to fluentd (via efluentc:post/2 api).
%% @end
empty(cast, {post, Tag, Data}, State = #state{buffer = Buffs, flush_timeout = Timeout}) ->
    Msg = encode_msg(Tag, Data),
    NewBuffs = <<Buffs/binary, Msg/binary>>,
    {next_state, buffered, State#state{buffer = NewBuffs}, flush_timeout_action(Timeout)};
empty(info, {tcp_closed, Sock}, State) ->
    safe_close_sock(Sock),
    {next_state, closed, State#state{sock = undefined}, reconnect_action(0)}.

%% @private
%% @doc
%% Empty buffered is ready to send messages to fluentd (via efluentc:post/2 api).
%% But theses messages is sent after flush_timeout msec.
%% @end
buffered(_Event, flush, State = #state{sock = Sock, tries = ?MAX_RETRY_COUNT}) ->
    safe_close_sock(Sock),
    {next_state, closed, State#state{tries = 0}};
buffered(_Event, flush, State) ->
    case buffered_send(State) of
        {{error, timeout}, NextState, NewState} ->
            ?ERR_LOG("send timeout", []),
            {next_state, NextState, NewState};
        {{error, Reason}, NextState, NewState} ->
            ?ERR_LOG("send failed: ~p", [Reason]),
            {next_state, NextState, NewState, reconnect_action(0)};
        {ok, NextState, NewState} ->
            {next_state, NextState, NewState}
    end;
buffered(cast, {post, Tag, Data}, State = #state{flush_timeout = Timeout}) ->
    Msg = encode_msg(Tag, Data),
    case append_buffer(Msg, State) of
        {buffer_overflow, NewState} ->
            {next_state, buffered, NewState, flush_action()};
        {ok, NewState} ->
            {next_state, buffered, NewState, flush_timeout_action(Timeout)}
    end;
buffered(info, {tcp_closed, Sock}, State) ->
    safe_close_sock(Sock),
    {next_state, closed, State#state{sock = undefined}, reconnect_action(0)}.

%% @private
%% @doc
%% @end
handle_event(_EventType, {'EXIT', Pid, Reason}, _StateName, State = #state{sock = Sock}) ->
    ?ERR_LOG("send failed: pid=~p, reason=~p", [Pid, Reason]),
    safe_close_sock(Sock),
    {next_state, closed, State};
handle_event(_EventType, {tcp_closed, S}, _State, State = #state{id = Id}) ->
    ?ERR_LOG("efluentc id=~w client closed[~w]", [Id, S, self()]),
    {next_state, closed, State};
handle_event(_EventType, _Content, _StateName, State) ->
    {next_state, flush, State}.

%% @private
%% @doc
%% @end
terminate(Reason, _StateName, #state{sock = Sock, buffer = Buffs}) when Sock =/= undefined ->
    ?ERR_LOG("VANISHED BUFFERS!: ~B byte", [byte_size(Buffs)]),
    ?ERR_LOG("terminated: ~p", [Reason]),
    safe_close_sock(Sock),
    ok;
terminate(Reason, _StateName, _State) ->
    ?ERR_LOG("terminated: ~p", [Reason]),
    ok.

%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

% @private
encode_msg(Tag, Data) when is_binary(Tag) and is_binary(Data) ->
    {Msec, Sec, _} = os:timestamp(),
    Package = [Tag, Msec*1000000+Sec, Data],
    msgpack:pack(Package, []);
encode_msg(Tag, Data) when is_binary(Tag) and is_list(Data) ->
    encode_msg(Tag, list_to_binary(Data));
encode_msg(Tag, Data) when is_binary(Tag) and is_map(Data) ->
    encode_msg(Tag, jiffy:encode(Data));
encode_msg(Tag, Data) when is_atom(Tag) and is_binary(Data) ->
    encode_msg(atom_to_binary(Tag, latin1), Data);
encode_msg(Tag, Data) when is_atom(Tag) and is_list(Data) ->
    encode_msg(atom_to_binary(Tag, latin1), list_to_binary(Data));
encode_msg(Tag, Data) when is_atom(Tag) and is_map(Data) ->
    encode_msg(atom_to_binary(Tag, latin1), jiffy:encode(Data)).

% @private
try_connect(State = #state{buffer = Buffs}) when byte_size(Buffs) > 0 ->
    try_connect(State, buffered);
try_connect(State) ->
    try_connect(State, empty).

% @private
try_connect(State = #state{host = Host, port = Port}, NextStateName) ->
    case gen_tcp:connect(Host, Port, ?GEN_TCP_OPTS) of
        {ok, Sock} ->
            gen_tcp:controlling_process(Sock, self()),
            {ok, State#state{sock = Sock}, NextStateName};
        {error, Reason} ->
            {error, Reason}
    end.

% @private
-spec buffered_send(State :: client_state()) -> {{error, Reason :: term()}, atom(), client_state()} | {ok, atom(), client_state()}.
buffered_send(State = #state{sock = Sock, buffer = Buff, buffer_caches = Caches, tries = Tries}) ->
    inet:setopts(Sock, [{active, once}]),
    case send(Sock, Buff, Caches) of
        {error, timeout, NewCaches} ->
            NewState = State#state{tries = Tries+1, buffer_caches = NewCaches},
            {{error, timeout}, buffered, NewState};
        {error, Reason, NewCaches} ->
            NewState = State#state{sock = undefined, buffer_caches = NewCaches},
            safe_close_sock(Sock),
            {{error, Reason}, closed, NewState};
        ok ->
            {ok, empty, State#state{buffer = <<>>}}
    end.

send(Sock, Buff, []) ->
    case gen_tcp:send(Sock, [Buff]) of
        {error, Reason} -> {error, Reason, []};
        ok -> ok
    end;
send(Sock, Buff, Caches = [CBuff|Rest]) ->
    case gen_tcp:send(Sock, [CBuff]) of
        {error, Reason} -> {error, Reason, Caches};
        ok -> send(Sock, Buff, Rest)
    end.


% @private
append_buffer(Msg, State = #state{buffer = Buffs, flush_buffer_size = FBS}) ->
    case <<Buffs/binary, Msg/binary>> of
        NewBuffs when FBS < byte_size(NewBuffs) ->
            {buffer_overflow, State#state{buffer = NewBuffs}};
        NewBuffs ->
            {ok, State#state{buffer = NewBuffs}}
    end.

% @private
append_buffer_caches(Buf, Caches = [_Old|Rest]) when length(Caches) > ?BUFFER_CACHE_SIZE ->
    % TODO: save spilled Old caches to file to send all buffered data after reconnect
    append_buffer_caches(Buf, Rest);
append_buffer_caches(Buf, Caches) ->
    lists:reverse([Buf|lists:reverse(Caches)]).


% @private
reconnect_action(N) ->
    [{{timeout, connect}, backoff(N), {reconnect, N}}].

% @private
flush_action() ->
    [{next_event, cast, flush}].

% @private
flush_timeout_action(Timeout) ->
    [{state_timeout, Timeout, flush}].

% @private
safe_close_sock(Sock) ->
    %TODO: safe close
    gen_tcp:close(Sock).

% @private
backoff(0) -> 1000;
backoff(1) -> 2000;
backoff(2) -> 2000;
backoff(3) -> 3000;
backoff(4) -> 3000;
backoff(5) -> 3000;
backoff(_) -> 5000.

% @private
errlog(Fmt, Args, File, Line) ->
    output(Fmt, Args, "ERROR", File, Line).

infolog(Fmt, Args, File, Line) ->
    output(Fmt, Args, "INFO", File, Line).

output(Fmt, Args, Label, File, Line) ->
    {{Y, M, D}, {HH, MM, SS}} = calendar:now_to_datetime(os:timestamp()),
    Timestamp = lists:flatten(io_lib:format(?DATE_FORMAT, [Y, M, D, HH, MM, SS])),
    NewFmt = lists:flatten(io_lib:format(?LOG_FORMAT, [Timestamp, Label, File, Line, Fmt])),
    io:format(NewFmt, Args).
