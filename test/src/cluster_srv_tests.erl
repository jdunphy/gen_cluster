-module(cluster_srv_tests).
-include_lib("eunit/include/eunit.hrl").
-include("debugger.hrl").

setup() ->
  erlang:display("calling start with 3"),
  {ok, Nodes} = test_util:start(3),
  Nodes.

teardown(Servers) ->
  test_util:shutdown(Servers),
  % wait for gproc to catch up with the dead processes
  timer:sleep(300).

node_state_test() ->
 {setup,
  fun setup/0,
  fun teardown/1,
  fun() ->
   ?assert(true =:= true),
   {ok, Plist} = gen_cluster:mod_plist(example_cluster_srv, node1),
   ?assertEqual(3, length(Plist)),
   {ok, _State1} = gen_cluster:call(node1, {state}),
   % ?assert(is_record(State1, state) =:= true),
   % ?assertEqual(testnode1, gen_cluster:call(testnode1, {registered_name})),
   passed
  end}.

cluster_is_updated_when_member_leaves_test() ->
  {setup,
   fun setup/0,
   fun teardown/1,
   fun() ->
    gen_cluster:cast(node1, stop),
    timer:sleep(300),
    {ok, Plist} = gen_cluster:mod_plist(example_cluster_srv, node0),
    ?assertEqual(2, length(Plist)),
    ?assertEqual(lists:sort([whereis(node0), whereis(node2)]), lists:sort(Plist)),
    passed
   end}.

cluster_members_are_notified_when_a_member_leaves_test() ->
  {setup, fun setup/0, fun teardown/1,
   fun() ->
    CrashingPid = whereis(node0),
    erlang:exit(CrashingPid, kill),
    timer:sleep(300),
    {ok, N1LastLeave} = gen_cluster:call(node1, get_last_leave),
    ?assertEqual(CrashingPid, N1LastLeave),
    {ok, N2LastLeave} = gen_cluster:call(node2, get_last_leave),
    ?assertEqual(CrashingPid, N2LastLeave),
    passed
   end}.

cluster_members_are_notified_when_a_new_member_joins_test() ->
  {setup, fun setup/0, fun teardown/1,
   fun() ->
    {ok, NewPid} = example_cluster_srv:start_named(node4, []),
    timer:sleep(300),
    {ok, N0LastJoin} = gen_cluster:call(node0, get_last_join),
    ?assertEqual(NewPid, N0LastJoin),
    {ok, N1LastJoin} = gen_cluster:call(node1, get_last_join),
    ?assertEqual(NewPid, N1LastJoin),
    {ok, N2LastJoin} = gen_cluster:call(node2, get_last_join),
    ?assertEqual(NewPid, N2LastJoin),
    erlang:exit(NewPid, kill),
    passed
   end}.

publish_test() ->
 {setup, fun setup/0, fun teardown/1,
  fun() ->
   {ok, Plist} = gen_cluster:mod_plist(example_cluster_srv, node1),
   [HeadPid|_] = Plist,
   gen_cluster:publish(example_cluster_srv, {hello, from, HeadPid}),

   timer:sleep(100),
   lists:foreach(fun(Pid) ->
     {ok, T} = gen_cluster:call(Pid, {get_msg}),
     ?assert(T == {hello, from, HeadPid})
   end, Plist),
   passed
  end}.

vote_test() ->
 {setup, fun setup/0, fun teardown/1,
  fun() ->
   O1 = gen_cluster:call_vote(example_cluster_srv, {run, server}),
   {ok, Plist} = gen_cluster:mod_plist(example_cluster_srv, node1),
   % In this test, the winner will always be the last element
   Winner = hd(lists:reverse(Plist)),
   ?assert(O1 == Winner),
   {ok, O2, _Result} = gen_cluster:ballot_run(example_cluster_srv, {set_msg, {hello, from, self()}}),
   {ok, Plist} = gen_cluster:mod_plist(example_cluster_srv, node1),
   {ok, NewMsg} = gen_cluster:call(O2, {get_msg}),
   ?assert({hello, from, self()} == NewMsg),
   % Now for one that doesn't have any participants
   Out = gen_cluster:ballot_run(example_cluster_srv, {something_i_dont_want_to_do, args}),
   ?assert(element(1, Out) =:= error),
   passed
  end}.

run_test() ->
 {setup, fun setup/0, fun teardown/1,
  fun() ->
   Msg = {hello, from, self()},
   {ok, Pid, _Output} = gen_cluster:run(example_cluster_srv, {set_msg, Msg}),
   {ok, NewMsg} = gen_cluster:call(Pid, {get_msg}),
   ?assert(Msg == NewMsg),
   passed
  end}.
