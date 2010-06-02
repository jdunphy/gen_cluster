-module (test_util).
-author("Ari Lerner <arilerner@mac.com>").
-export ([
  start/1,
  shutdown/1,
  context_run/2
]).

start(Count) -> start(Count, 0, []).
start(Count, Count, Acc) -> {ok, Acc};
start(Count, CurrentCount, Acc) ->
  Name = erlang:list_to_atom(lists:flatten(["node", erlang:integer_to_list(CurrentCount)])),
  Seed = case erlang:length(Acc) of
    0 -> undefined;
    _ -> whereis(erlang:hd(Acc))
  end,
  {ok, _NodePid} = example_cluster_srv:start_named(Name, [{seed, Seed}]),
  start(Count, CurrentCount + 1, [Name|Acc]).
  
shutdown([]) -> ok;
shutdown([Pname|Rest]) -> 
  Pid = whereis(Pname),
  gen_cluster:cast(Pid, stop), 
  try unregister(Pname)
  catch _:_ -> ok
  end,
  shutdown(Rest).

context_run(Count, Fun) ->
  {ok, Nodes} = start(Count),
  Fun(),
  shutdown(Nodes).