-module(eunit_example_cluster_srv).
-include_lib("eunit/include/eunit.hrl").
-include ("debugger.hrl").
-compile(export_all).

setup() ->
  {ok, Nodes} = test_util:start(3),
  Nodes.

teardown(Servers) ->
  test_util:shutdown(Servers).

all_test_() ->
  {"Node testing",
    [
      {"Test node state", fun node_state/0},
      {"Test global takeover", fun node_global_takeover/0},
      {"Test add a child", fun add_child/0},
      {"Test different type of failure", fun do_some_more/0},
      {"Test different type of node", fun different_type_of_node/0}
    ]
  }.
  
node_state() ->
  {
    setup, fun setup/0, fun teardown/1,
    fun () ->
      ?assert(true =:= true),
      {ok, Plist} = gen_cluster:mod_plist(example_cluster_srv, node1),
      ?assertEqual(3, length(Plist)),
      {ok, _State1} = gen_cluster:call(node1, {state}),
      % ?assert(is_record(State1, state) =:= true),
      % ?assertEqual(testnode1, gen_cluster:call(testnode1, {registered_name})),
      {ok}
    end
  }.

node_global_takeover() ->
  {
      setup, fun setup/0, fun teardown/1,
      fun () ->
         Node1Pid = whereis(node1),
         {ok, Name1} = gen_cluster:call(Node1Pid, {'$gen_cluster', globally_registered_name}),

         GlobalPid1 = global:whereis_name(Name1),
         ?assert(is_process_alive(GlobalPid1)),

         gen_cluster:cast(Node1Pid, stop),
         timer:sleep(500),

         GlobalPid2 = global:whereis_name(Name1),
         ?assert(GlobalPid1 =/= GlobalPid2),
         ?assert(is_process_alive(GlobalPid2)),

         % {ok, _Node4Pid} = example_cluster_srv:start_named(node4, {seed, GlobalPid2}),
         {ok}
      end
  }.

different_type_of_node() ->
  {
    setup, fun setup/0, fun teardown/1,
    fun() ->
      Node1Pid = whereis(node1),
      Node2Pid = whereis(node2),
      Node3Pid = whereis(node3),

      {ok, Node4Pid} = other_example_cluster_srv:start_named(node4, [{seed, Node1Pid}, {leader_pids, Node1Pid}]),
      {ok, TwoPlist} = gen_cluster:plist(node1),
      ?assertEqual(2, length(TwoPlist)),

      ExampleC = proplists:get_value(example_cluster_srv, TwoPlist),
      ?assertEqual(3, length(ExampleC)),
      ?assertEqual([Node3Pid, Node2Pid, Node1Pid], ExampleC),

      OtherC = proplists:get_value(other_example_cluster_srv, TwoPlist),
      ?assertEqual(1, length(OtherC)),
      ?assertEqual([Node4Pid], OtherC),

      % Kill off one and make sure the rest still match
      gen_cluster:cast(Node3Pid, stop),
      timer:sleep(500),

      Node2Plist = gen_cluster:plist(node2),
      Node4Plist = gen_cluster:plist(node4),
      % erlang:display({Node2Plist, Node4Plist}),
      ?assertEqual(Node2Plist, Node4Plist),

      teardown([node4]),
      {ok}
    end
  }.

do_some_more() ->
  fun() ->
    {ok, Pid} = example_cluster_srv:start(),
    {ok, Pid2} = example_cluster_srv:expand_clone(Pid),
    {ok, _Pid3} = example_cluster_srv:expand_clone(Pid),
    {ok, Proplists} = gen_cluster:plist(example_cluster_srv),
    OrigLeader = gen_cluster:leader(Pid),
    gen_server:cast(Pid, stop),
    timer:sleep(500),
    NewLeader = gen_cluster:leader(Pid2),
    ?assertEqual(3, length(proplists:get_value(example_cluster_srv, Proplists))),
    ?assert(OrigLeader =/= NewLeader),
    ok
  end.

add_child() ->
  {setup, fun setup/0, fun teardown/1,
    fun() ->
      {ok, Pid} = dummy_gen_server:start_link(),
      Node1Pid = whereis(node1),
      gen_cluster:add_child(Node1Pid, dummy_gen_server, Pid),
      {ok, Proplists} = gen_cluster:plist(node1),
      ?assertEqual(1, length(proplists:get_value(dummy_gen_server, Proplists))),
      ok
    end
  }.

% {ok, _Node4Pid} = other_example_cluster_srv:start_named(node4, {seed, Node1Pid}),

% node_leavenot() ->
%   {
%       setup, fun setup/0,
%       fun () ->
%          ?assert(true =:= true),
%          {ok}
%       end
%   }.

