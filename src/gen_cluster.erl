%%%-------------------------------------------------------------------
%%% File    : stoplight_srv.erl
%%% Author  : nmurray@attinteractive.com, alerner@attinteractive.com
%%% Description : Cascading gen_server behavior that implements process clustering.  
%%% See: http://wiki.trapexit.org/index.php/Cascading_Behaviours
%%% Created     : 2009-08-03
%%%
%%% NOTES:
%%% * uses distributed erlang (today)
%%% * registers one global pid in the format of "gen_cluster_" ++
%%%   atom_to_list(Mod) where Mod is the module using gen_cluster. This allows
%%%   for one "rallying point" for each new node that joins the cluster.
%%% * If the node holding the rally point fails, a new node needs to take over the registered name
%%%-------------------------------------------------------------------
-module(gen_cluster).
-include_lib("../include/gen_cluster.hrl").

%% Define this module as a gen_server callback module.
-behaviour(gen_server).

%% Export the same API as gen_server.
-export([start/3, start/4,
    start_link/3, start_link/4,
    call/2, call/3,
    cast/2, reply/2,
    abcast/2, abcast/3,
    multi_call/2, multi_call/3, multi_call/4,
    enter_loop/3, enter_loop/4, enter_loop/5, wake_hib/5]).

%% Export the callbacks that gen_server expects
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% Define the behaviour's required callbacks.
-export([behaviour_info/1]).

%% Helper functions
-export([
  plist/1,
  mod_plist/2,
  publish/2,
  run/2,
  ballot_run/2,
  call_vote/2
]).

behaviour_info(callbacks) ->
    [
    % gen_cluster
      {handle_join, 2}, {handle_leave, 3},
    % gen_server
      {init,1}, {handle_call,3},{handle_cast,2},{handle_info,2}, {terminate,2},{code_change,3}
   ];

behaviour_info(_) ->
    undefined.

%% State data record.
-record(state, {
  module,       % module name started
  state,        % mod's state
  data,         % user mod's data
  plist         % cached copy of cluster members' list
}).

%% debugging helper
-include ("debugger.hrl").

%% Users will use these start functions instead of gen_server's.
%% We add the user's module name to the arguments and call
%% server's start function with our module name instead.
start(Mod, Args, Options) ->
  gen_server:start(?MODULE, [Mod, Args], Options).
start(Name, Mod, Args, Options) ->
  gen_server:start(Name, ?MODULE, [Mod, Args], Options).
start_link(Mod, Args, Options) ->
  gen_server:start(?MODULE, [Mod, Args], Options).
start_link(Name, Mod, Args, Options) ->
  gen_server:start(Name, ?MODULE, [Mod, Args], Options).

%% Delegate the rest of the reqests to gen_server
call(Name, Request) ->
  gen_server:call(Name, Request).
call(Name, Request, Timeout) ->
 gen_server:call(Name, Request, Timeout).
cast(Name, Request) ->
  gen_server:cast(Name, Request).
reply(To, Reply) ->
  gen_server:reply(To, Reply).
abcast(Name, Request) ->
  gen_server:abcast(Name, Request).
abcast(Nodes, Name, Request) ->
  gen_server:abcast(Nodes, Name, Request).
multi_call(Name, Req) ->
  gen_server:multi_call(Name, Req).
multi_call(Nodes, Name, Req)  ->
  gen_server:multi_call(Nodes, Name, Req).
multi_call(Nodes, Name, Req, Timeout)  ->
  gen_server:multi_call(Nodes, Name, Req, Timeout).
enter_loop(Mod, Options, State) ->
  gen_server:enter_loop(Mod, Options, State).
enter_loop(Mod, Options, State, Timeout) ->
  gen_server:enter_loop(Mod, Options, State, Timeout).
enter_loop(Mod, Options, State, ServerName, Timeout) ->
  gen_server:enter_loop(Mod, Options, State, ServerName, Timeout).
wake_hib(Parent, Name, State, Mod, Debug) ->
  gen_server:wake_hib(Parent, Name, State, Mod, Debug).

plist(PidRef) -> % {ok, Plist}
  call(PidRef, {'$gen_cluster', plist}).
  
mod_plist(Type, PidRef) ->
  call(PidRef, {'$gen_cluster', mod_plist, Type}).

publish(Mod, Msg) when is_atom(Mod) ->
  do_publish(Mod, Msg).

% Run a vote, if none come back, force one to run
run(Mod, Msg) ->
  case ballot_run(Mod, Msg) of
    {error, no_winner} ->
      % Force a run
      P = randomly_pick(gproc:lookup_pids({p,g,cluster_key(Mod)}), []),
      call(P, Msg, infinity);
    {error, _} = T -> T;
    {ok, _, _} = Good -> Good
  end.

% Run through a vote and run the function
ballot_run(Mod, Msg) -> 
  case call_vote(Mod, Msg) of
    Pid when is_pid(Pid) -> 
      case catch call(Pid, Msg, infinity) of
        {'EXIT', Err} -> {error, Err};
        T -> {ok, Pid, T}
      end;
    {error, _Reason} = T ->
      % erlang:display({could_not_run, Reason}),
      T
  end.
  
% Call vote and get the PID
call_vote(Mod, Msg) ->
  do_call_vote(Mod, Msg).

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%
%% run the user's init/1 and store the user's state data in our internal
%% state data record for later reference.
%%--------------------------------------------------------------------

init([Mod, Args]) ->
  InitialState = #state{module = Mod},
  
  start_gproc_if_necessary(InitialState),
  {ok, State} = join_cluster(InitialState),

  ?TRACE("Starting state", State),

  case Mod:init(Args) of
    {ok, ExtState} ->
      StateData = State#state{state = ExtState},
      {ok, StateData};
    {ok, ExtStateName, ExtStateData} ->
      StateData = State#state{state = ExtStateName, data = ExtStateData},
      {ok, StateData};
    {ok, ExtStateName, ExtStateData, Timeout} ->
      StateData = State#state{state = ExtStateName, data = ExtStateData},
      {ok, StateData, Timeout};
    {stop, Reason} ->
      {stop, Reason};
    Other ->
      ?TRACE("got other:", Other),
      exit(bad_gen_cluster_init_call) % hmmm
  end.

%%--------------------------------------------------------------------
%% Function:  handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                        {reply, Reply, State, Timeout} |
%%                                                      {noreply, State} |
%%                                             {noreply, State, Timeout} |
%%                                          {stop, Reason, Reply, State} |
%%                                                 {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({'$gen_cluster', join, Pid}, From, State) ->
  ?TRACE("$gen_cluster join", State),
  {ok, NewState} = handle_pid_joining(Pid, From, State),
  {reply, ok, NewState};

handle_call({'$gen_cluster', plist}, _From, State) ->
  Reply = {ok, cluster_pids(State)},
  {reply, Reply, State};
  
handle_call({'$gen_cluster', mod_plist, Mod}, _From, State) ->
  Pids = gproc:lookup_pids({p,g,cluster_key(Mod)}),
  {reply, {ok, Pids}, State};

handle_call({'$gen_cluster', handle_vote_called, Msg}, From, #state{module = Mod, state = ExtState} = State) ->
  Reply = case erlang:function_exported(Mod, handle_vote, 2) of
    false -> {reply, 0, State};
    true -> Mod:handle_vote(Msg, ExtState)
  end,
  handle_call_reply(Reply, From, State);

handle_call(Request, From, State) ->
  Mod = State#state.module,
  ExtState = State#state.state,
  Reply = Mod:handle_call(Request, From, ExtState),
  handle_call_reply(Reply, From, State).

% handle the replies by updating and substituting our own state
handle_call_reply({reply, Reply, ExtState}, _From, State) ->
  NewState = State#state{state=ExtState},
  {reply, Reply, NewState};

handle_call_reply({reply, Reply, ExtState, Timeout}, _From, State) ->
  NewState = State#state{state=ExtState},
  {reply, Reply, NewState, Timeout};

handle_call_reply({noreply, ExtState}, _From, State)  ->
  NewState = State#state{state=ExtState},
  {noreply, NewState};

handle_call_reply({noreply, ExtState, Timeout}, _From, State) ->
  NewState = State#state{state=ExtState},
  {noreply, NewState, Timeout};

handle_call_reply({stop, Reason, Reply, ExtState}, _From, State)  ->
  NewState = State#state{state=ExtState},
  {stop, Reason, Reply, NewState};

handle_call_reply({stop, Reason, ExtState}, _From, State) ->
  NewState = State#state{state=ExtState},
  {stop, Reason, NewState}.
  % handle Other?

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(Msg, State) ->
  Mod = State#state.module,
  ExtState = State#state.state,
  Reply = Mod:handle_cast(Msg, ExtState),
  handle_cast_info_reply(Reply, State).

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _MonitorRef, process, Pid, Info} = T, #state{module = Mod} = State) ->
  ?TRACE("received 'DOWN'. Info:", Info),
  case handle_pid_leaving(Pid, Info, State) of
    {false, #state{state = ExtState} = _NoPidNewState} ->
      Reply = Mod:handle_info(T, ExtState),
      handle_cast_info_reply(Reply, State);
    {true, TheNewState} when is_record(TheNewState, state) ->
      {noreply, TheNewState};
    E ->
      erlang:display({?MODULE, ?LINE, error, {unknown, E}})
  end;

handle_info({'$gen_cluster', handle_publish, Msg}, #state{module = Mod, state = ExtState} = State) ->
  case erlang:function_exported(Mod, handle_publish, 2) of
    false -> handle_cast_info_reply({noreply, ExtState}, State);
    true ->
      ?TRACE("Got a PUBLISH message: ~p", Msg),
      Mod = State#state.module,
      ExtState = State#state.state,
      Reply = Mod:handle_publish(Msg, ExtState),
      handle_publish_reply(Reply, State)
  end;

handle_info(Info, State) ->
    ?TRACE("got other INFO", Info),
    Mod = State#state.module,
    ExtState = State#state.state,
    Reply = Mod:handle_info(Info, ExtState),
    handle_cast_info_reply(Reply, State).

handle_cast_info_reply({noreply, ExtState}, State) ->
    NewState = State#state{state=ExtState},
    {noreply, NewState};
handle_cast_info_reply({noreply, ExtState, Timeout}, State) ->
    NewState = State#state{state=ExtState},
    {noreply, NewState, Timeout};
handle_cast_info_reply({stop, Reason, ExtState}, State) ->
    NewState = State#state{state=ExtState},
    {stop, Reason, NewState}.


handle_publish_reply({ok, ExtState}, State) ->
  {noreply, State#state{state = ExtState}};
handle_publish_reply({noreply, ExtState}, State) ->
  {noreply, State#state{state = ExtState}};
handle_publish_reply({stop, Reason, ExtState}, State) ->
  {stop, Reason, State#state{state=ExtState}}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(Reason, State) ->
    Mod = State#state.module,
    ExtState = State#state.state,
    _ = Mod:terminate(Reason, ExtState),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(OldVsn, State, Extra) ->
    Mod = State#state.module,
    ExtState = State#state.state,
    {ok, NewExtState} = Mod:code_change(OldVsn, ExtState, Extra),
    NewState = State#state{state=NewExtState},
    {ok, NewState}.


handle_pid_joining(Pid, _From, State) ->
  ?TRACE("handle_pid_joining", Pid),
  monitor_pid(Pid),

  % callback
  #state{module=Mod, state=ExtState} = State,
  StateData = case Mod:handle_join(Pid, ExtState) of
      {ok, NewExtState} -> State#state{state = NewExtState};
      _Else -> State
  end,

  Plist = StateData#state.plist,
  NewState = StateData#state{plist = [Pid|Plist]},
  {ok, NewState}.

handle_pid_leaving(Pid, Info, State) ->
  ExtState = State#state.state,
  Mod = State#state.module,
  case lists:member(Pid, State#state.plist) of
    true ->
      % XXX: There's a bug in gproc that prevents it from removing
      % keys when a remote node goes away. This should do the trick for now.
      cleanup_gproc_data_from_dead_pid(cluster_key(State#state.module), Pid),
      {ok, NewExtState} = Mod:handle_leave(Pid, Info, ExtState),
      OldPlist = State#state.plist,
      NewPlist = lists:delete(Pid, OldPlist),
      {true, State#state{state=NewExtState, plist=NewPlist}};
    false -> {false, State}
  end.

cleanup_gproc_data_from_dead_pid(Key, Pid) ->
  catch gproc_dist:leader_call({unreg, {p,g,Key}, Pid}).

cluster_key(Mod) ->
  {gen_cluster, Mod}.

cluster_pids(State) ->
  gproc:lookup_pids({p,g,cluster_key(State#state.module)}).

monitor_pid(Pid) when is_pid(Pid) ->
  case Pid =/= self() of
    false -> ok;
    true -> erlang:monitor(process, Pid)
  end.

join_cluster(State) ->
  gproc:reg({p,g,cluster_key(State#state.module)}),
  lists:foreach(
    fun(Pid) ->
      case Pid =/= self() of
	true ->
	  monitor_pid(Pid),
	  call(Pid, {'$gen_cluster', join, self()});
        false -> ok
      end
    end,
    cluster_pids(State)),

  NewState = State#state{plist = cluster_pids(State)},
  {ok, NewState}.


% publish through gproc
do_publish(Mod, Msg) ->
  lists:foreach(fun(Pid) ->
    do_send(Pid, {'$gen_cluster', handle_publish, Msg})
  end, gproc:lookup_pids({p,g,cluster_key(Mod)})).

% Call vote
do_call_vote(Mod, Msg) ->
  OriginalVotes = lists:map(fun(Pid) ->    
    Vote = case catch gen_server:call(Pid, {'$gen_cluster', handle_vote_called, Msg}) of
      {'EXIT', _} -> 0;
      {error, _} -> 0;
      E -> E
    end,
    {Pid, Vote}
  end, gproc:lookup_pids({p,g,cluster_key(Mod)})),
  case lists:filter(fun({_, Vote}) -> Vote > 0 end, OriginalVotes) of
    [] -> {error, no_winner};
    Votes ->
      [{WinnerPid, _WinnerVote}|_Rest] = lists:sort(fun({_Pid1, Vote1},{_Pid2, Vote2}) -> Vote1 > Vote2 end, Votes),
      WinnerPid
  end.
  
do_send(Pid, Msg) ->
  case catch erlang:send(Pid, Msg, [noconnect]) of
	  noconnect -> spawn(erlang, send, [Pid,Msg]);
	  Other -> Other
  end.

get_seed_nodes(#state{module = Mod, state = ExtState} = _State) ->
  Nodes1 = case os:getenv("GPROC_SEEDS") of
    false -> [node()];
    E -> lists:map(fun(Node) ->
      case Node of
        List when is_list(List) -> erlang:list_to_atom(List);
        Atom -> Atom
      end
    end, [node()|E])
  end,
  Nodes2 = case erlang:function_exported(Mod, seed_nodes, 1) of
    true -> 
      case Mod:seed_nodes(ExtState) of
        undefined -> Nodes1;
        [undefined] -> Nodes1;
        List when is_list(List) -> lists:append([List, Nodes1]);
        APid when is_pid(APid) -> [node(APid)|Nodes1];
        ANode -> [ANode|Nodes1]
      end;
    false -> Nodes1
  end,
  Nodes3 = case whereis(Mod) of % join unless we are the main server 
    undefined -> Nodes2;
    X when X =:= self() -> Nodes2;
    Pid when is_pid(Pid) -> [node(Pid)|Nodes2];
    Node -> [Node|Nodes2]
  end,
  lists:usort(Nodes3). % get unique elements

start_gproc_if_necessary(State) ->
  case whereis(gproc) of
    undefined ->
      %{ok, [[Seed]]} = init:get_argument(gen_cluster_known),
      %Seed = init:get_argument(gen_cluster_known),
      Seeds = get_seed_nodes(State),
      
      % Ping the nodes
      [ net_adm:ping(S) || S <- Seeds ],
      application:set_env(gproc, gproc_dist, Seeds),
      application:start(gproc);
    _ -> ok
  end.

randomly_pick([], Acc) -> hd(Acc);
randomly_pick(Bees, Acc) ->
  RandNum = random:uniform(length(Bees)),
  Bee = lists:nth(RandNum, Bees),
  NewBees = lists:delete(Bee, Bees),
  randomly_pick(NewBees, [Bee|Acc]).
