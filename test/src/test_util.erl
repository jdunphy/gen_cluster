-module (test_util).
-author("Ari Lerner <arilerner@mac.com>").
-export ([
  start/1,
  start/2,
  shutdown/1,
  context_run/2
]).

start(Count)      -> start(Count, example_cluster_srv, 0, []).
start(Count, Mod) -> start(Count, Mod, 0, []).
start(Count, _Mod, Count, Acc) -> {ok, Acc};
start(Count, Mod, CurrentCount, Acc) ->
  Name = erlang:list_to_atom(lists:flatten(["node", erlang:integer_to_list(CurrentCount)])),
  {ok, _NodePid} = Mod:start_named(Name, []),
  start(Count, Mod, CurrentCount + 1, [Name|Acc]).

shutdown([]) -> ok;
shutdown([Pname|Rest]) ->
  case whereis(Pname) of
    undefined -> ok;
    Pid ->
      case is_process_alive(Pid) of
	false -> ok;
	true ->
          gen_cluster:cast(Pid, stop),
          try unregister(Pname)
          catch _:_ -> ok
          end
      end
  end,
  shutdown(Rest).

context_run(Count, Fun) ->
  {ok, Nodes} = start(Count),
  Fun(),
  shutdown(Nodes).
