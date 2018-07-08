%%%-------------------------------------------------------------------
%%% @author tkyshm
%%% @copyright (C) 2017, tkyshm
%%% @doc
%%%
%%% @end
%%% Created : 2017-11-03 12:54:42.837001
%%%-------------------------------------------------------------------
-module(efluentc_SUITE).


%% API
-export([all/0,
         suite/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         group/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

%% test cases
-export([
         t_post/1,
         t_post_buffered_data/1
        ]).

%-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").

%-define(PROPTEST(M,F), true = proper:quickcheck(M:F())).

all() ->
    [
     {group, test}
    ].

suite() ->
    [{ct_hooks, [cth_surefire]}, {timetrap, {seconds, 60}}].

groups() ->
    [
     {test, [], [
                 t_post,
                 t_post_buffered_data
                ]}
    ].

%%%===================================================================
%%% Overall setup/teardown
%%%===================================================================
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(efluentc),
    Config.

end_per_suite(_Config) ->
    application:stop(efluentc),
    ok.


%%%===================================================================
%%% Group specific setup/teardown
%%%===================================================================
group(_Groupname) ->
    [].

init_per_group(_Groupname, Config) ->
    Config.

end_per_group(_Groupname, _Config) ->

    ok.


%%%===================================================================
%%% Testcase specific setup/teardown
%%%===================================================================
init_per_testcase(t_post, Config) ->
    fluentd_mock:start_link(self()),
    timer:sleep(2000),
    Config;
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(t_post, _Config) ->
    fluentd_mock:stop(),
    ok;
end_per_testcase(_Case, _Config) ->
    ok.


%%%===================================================================
%%% Individual Test Cases (from groups() definition)
%%%===================================================================
t_post(Config) ->
    TestCase =
    [
     % Tag :: binary(), Msg:: binary()
     {<<"test.tag">>, <<"message">>},

     % Tag :: binary(), Msg:: list()
     {<<"test.tag">>, "message" },

     % Tag :: binary(), Msg:: map()
     {<<"test.tag">>, #{<<"message">> => <<"hello world">>}},

     % Tag :: atom(), Msg:: binary()
     {'test.tag', <<"message">>},

     % Tag :: atom(), Msg:: list()
     {'test.tag', "message"},

     % Tag :: atom(), Msg:: map()
     {'test.tag', #{<<"message">> => <<"hello world">>}}
    ],

    PostTestFn =
    fun(Tag, Msg) ->
            efluentc:post(Tag, Msg),
            {WantTag, WantMsg} = convert_tag_msg(Tag, Msg),
            receive
                {_, RecvMsg} ->
                    {ok, [GotTag, _, GotMsg]} = msgpack:unpack(RecvMsg, [{unpack_str, as_binary}]),
                    GotTag = WantTag,
                    GotMsg = WantMsg
            after 3000 ->
                ct:fail(timeout_receive)
            end
    end,

    [PostTestFn(Tag, Msg)
     || {Tag, Msg} <- TestCase],

    Config.

t_post_buffered_data(Config) ->
    Tag = <<"test.tag">>,
    Msg = <<"message">>,
    ByteSize = 25, % byte size of tag and msg packed by msgpack

    [efluentc:post(Tag, Msg) || _ <- lists:seq(1, 10)],
    fluentd_mock:start_link(self()),
    timer:sleep(2000),

    % efluentc default 2 worker, so receive 2 times.
    % 1 worker
    receive
        {_, RecvMsg1} ->
            Num1 = byte_size(RecvMsg1) div ByteSize,
            lists:foldl(fun(_, Acc) ->
                                <<PerMsg:ByteSize/binary, Rest/binary>> = Acc,
                                {ok, [Tag, _, Msg]} = msgpack:unpack(PerMsg),
                                Rest
                        end, RecvMsg1, lists:seq(1, Num1))

    after 3000 ->
              ct:fail(timeout_receive)
    end,

    % 2 worker
    receive
        {_, RecvMsg2} ->
            Num2 = byte_size(RecvMsg2) div ByteSize,
            lists:foldl(fun(_, Acc) ->
                                <<PerMsg:ByteSize/binary, Rest/binary>> = Acc,
                                {ok, [Tag, _, Msg]} = msgpack:unpack(PerMsg),
                                Rest
                        end, RecvMsg2, lists:seq(1, Num2))

    after 3000 ->
              ct:fail(timeout_receive)
    end,

    Config.

convert_tag_msg(Tag, Msg) when is_atom(Tag) and is_list(Msg) ->
    BinTag = atom_to_binary(Tag, latin1),
    BinMsg = list_to_binary(Msg),
    {BinTag, BinMsg};
convert_tag_msg(Tag, Msg) when is_atom(Tag) and is_map(Msg) ->
    BinTag = atom_to_binary(Tag, latin1),
    {BinTag, Msg};
convert_tag_msg(Tag, Msg) when is_atom(Tag) ->
    BinTag = atom_to_binary(Tag, latin1),
    {BinTag, Msg};
convert_tag_msg(Tag, Msg) when is_list(Msg) ->
    BinMsg = list_to_binary(Msg),
    {Tag, BinMsg};
convert_tag_msg(Tag, Msg) when is_map(Msg) ->
    {Tag, Msg};
convert_tag_msg(Tag, Msg) ->
    {Tag, Msg}.
