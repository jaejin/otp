%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2010-2012. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

-module(diameter_peer).

-behaviour(gen_server).

%% Interface towards transport modules ...
-export([recv/2,
         up/1,
         up/2]).

%% ... and the stack.
-export([start/1,
         send/2,
         close/1,
         abort/1,
         notify/2]).

%% Old interface only called from old code.
-export([start/3]).  %% < diameter-1.2 (R15B02)

%% Server start.
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

%% debug
-export([state/0,
         uptime/0]).

-include_lib("diameter/include/diameter.hrl").
-include("diameter_internal.hrl").

%% Registered name of the server.
-define(SERVER, ?MODULE).

%% Server state.
-record(state, {id = now()}).

%% Default transport_module/config.
-define(DEFAULT_TMOD, diameter_tcp).
-define(DEFAULT_TCFG, []).
-define(DEFAULT_TTMO, infinity).

%%% ---------------------------------------------------------------------------
%%% # notify/2
%%% ---------------------------------------------------------------------------

notify(SvcName, T) ->
    rpc:abcast(nodes(), ?SERVER, {notify, SvcName, T}).

%%% ---------------------------------------------------------------------------
%%% # start/3
%%% ---------------------------------------------------------------------------

%% From old code: make is restart.
start(_T, _Opts, #diameter_service{}) ->
    {error, restart}.

%%% ---------------------------------------------------------------------------
%%% # start/1
%%% ---------------------------------------------------------------------------

-spec start({T, [Opt], #diameter_service{}})
   -> {TPid, [Addr], Tmo, Data}
    | {error, [term()]}
 when T    :: {connect|accept, diameter:transport_ref()},
      Opt  :: diameter:transport_opt(),
      TPid :: pid(),
      Addr :: inet:ip_address(),
      Tmo  :: non_neg_integer() | infinity,
      Data :: {{T, Mod, Cfg}, [Mod], [{T, [Mod], Cfg}], [Err]},
      Mod  :: module(),
      Cfg  :: term(),
      Err  :: term()
    ; ({#diameter_service{}, Tmo, Data})
   -> {TPid, [Addr], Tmo, Data}
    | {error, [term()]}
 when TPid :: pid(),
      Addr :: inet:ip_address(),
      Tmo  :: non_neg_integer() | infinity,
      Data :: {{T, Mod, Cfg}, [Mod], [{T, [Mod], Cfg}], [Err]},
      T    :: {connect|accept, diameter:transport_ref()},
      Mod  :: module(),
      Cfg  :: term(),
      Err  :: term().

%% Initial start.
start({T, Opts, #diameter_service{} = Svc}) ->
    start(T, Svc, pair(Opts, [], []), []);

%% Subsequent start.
start({#diameter_service{} = Svc, Tmo, {{T, _, Cfg}, Ms, Rest, Errs}}) ->
    start(T, Ms, Cfg, Svc, Tmo, Rest, Errs).

%% pair/3
%%
%% Pair transport modules with config.

%% Another transport_module: accumulate it.
pair([{transport_module, M} | Rest], Mods, Acc) ->
    pair(Rest, [M|Mods], Acc);

%% Another transport_config: accumulate another tuple.
pair([{transport_config = T, C} | Rest], Mods, Acc) ->
    pair([{T, C, ?DEFAULT_TTMO} | Rest], Mods, Acc);
pair([{transport_config, C, Tmo} | Rest], Mods, Acc) ->
    pair(Rest, [], acc({Mods, C, Tmo}, Acc));

pair([_ | Rest], Mods, Acc) ->
    pair(Rest, Mods, Acc);

%% No transport_module or transport_config: defaults.
pair([], [], []) ->  
    [{[?DEFAULT_TMOD], ?DEFAULT_TCFG, ?DEFAULT_TTMO}];

%% One transport_module, one transport_config.
pair([], [M], [{[], Cfg, Tmo}]) ->
    [{[M], Cfg, Tmo}];

%% Trailing transport_module: default transport_config.
pair([], [_|_] = Mods, Acc) ->
    lists:reverse(acc({Mods, ?DEFAULT_TCFG, ?DEFAULT_TTMO}, Acc));

pair([], [], Acc) ->
    lists:reverse(def(Acc)).

%% acc/2

acc(T, Acc) ->
    [T | def(Acc)].

%% def/1
%%
%% Default module of previous pair if none were specified.

def([{[], Cfg, Tmo} | Acc]) ->
    [{[?DEFAULT_TMOD], Cfg, Tmo} | Acc];
def(Acc) ->
    Acc.

%% start/4

start(T, Svc, [{Ms, Cfg, Tmo} | Rest], Errs) ->
    start(T, Ms, Cfg, Svc, Tmo, Rest, Errs);

start(_, _, [], Errs) ->
    {error, Errs}.

%% start/7

start(T, [], _, Svc, _, Rest, Errs) ->
    start(T, Svc, Rest, Errs);

start(T, [M|Ms], Cfg, Svc, Tmo, Rest, Errs) ->
    case start(M, [T, Svc, Cfg]) of
        {ok, TPid} ->
            {TPid, [], Tmo, {{T, M, Cfg}, Ms, Rest, Errs}};
        {ok, TPid, [_|_] = Addrs} ->
            {TPid, Addrs, Tmo, {{T, M, Cfg}, Ms, Rest, Errs}};
        E ->
            start(T, Ms, Cfg, Svc, Tmo, Rest, [E|Errs])
    end.

%% start/2

start(Mod, Args) ->
    apply(Mod, start, Args).

%%% ---------------------------------------------------------------------------
%%% # up/[12]
%%% ---------------------------------------------------------------------------

up(Pid) ->  %% accepting transport
    ifc_send(Pid, {self(), connected}).

up(Pid, Remote) ->  %% connecting transport
    ifc_send(Pid, {self(), connected, Remote}).

%%% ---------------------------------------------------------------------------
%%% # recv/2
%%% ---------------------------------------------------------------------------

recv(Pid, Pkt) ->
    ifc_send(Pid, {recv, Pkt}).

%%% ---------------------------------------------------------------------------
%%% # send/2
%%% ---------------------------------------------------------------------------

send(Pid, #diameter_packet{transport_data = undefined,
			   bin = Bin}) ->
    send(Pid, Bin);

send(Pid, Pkt) ->
    ifc_send(Pid, {send, Pkt}).

%%% ---------------------------------------------------------------------------
%%% # close/1
%%% ---------------------------------------------------------------------------

close(Pid) ->
    ifc_send(Pid, {close, self()}).

%%% ---------------------------------------------------------------------------
%%% # abort/1
%%% ---------------------------------------------------------------------------

abort(Pid) ->
    exit(Pid, shutdown).

%% ---------------------------------------------------------------------------
%% ---------------------------------------------------------------------------

start_link() ->
    ServerName = {local, ?SERVER},
    Module     = ?MODULE,
    Args       = [],
    Options    = [{spawn_opt, diameter_lib:spawn_opts(server, [])}],
    gen_server:start_link(ServerName, Module, Args, Options).

state() ->
    call(state).

uptime() ->
    call(uptime).

%%% ----------------------------------------------------------
%%% # init(Role)
%%% ----------------------------------------------------------

init([]) ->
    {ok, #state{}}.

%%% ----------------------------------------------------------
%%% # handle_call(Request, From, State)
%%% ----------------------------------------------------------

handle_call(state, _, State) ->
    {reply, State, State};

handle_call(uptime, _, #state{id = Time} = State) ->
    {reply, diameter_lib:now_diff(Time), State};

handle_call(Req, From, State) ->
    ?UNEXPECTED([Req, From]),
    {reply, nok, State}.

%%% ----------------------------------------------------------
%%% # handle_cast(Request, State)
%%% ----------------------------------------------------------

handle_cast(Msg, State) ->
    ?UNEXPECTED([Msg]),
    {noreply, State}.

%%% ----------------------------------------------------------
%%% # handle_info(Request, State)
%%% ----------------------------------------------------------

%% Remote service is distributing a message.
handle_info({notify, SvcName, T}, S) ->
    bang(diameter_service:whois(SvcName), T),
    {noreply, S};

handle_info(Info, State) ->
    ?UNEXPECTED([Info]),
    {noreply, State}.

%% ----------------------------------------------------------
%% terminate(Reason, State)
%% ----------------------------------------------------------

terminate(_Reason, _State) ->
    ok.

%% ----------------------------------------------------------
%% code_change(OldVsn, State, Extra)
%% ----------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ---------------------------------------------------------
%% INTERNAL FUNCTIONS
%% ---------------------------------------------------------

%% ifc_send/2
%%
%% Send something over the transport interface.

ifc_send(Pid, T) ->
    Pid ! {diameter, T}.

%% bang/2

bang(undefined = No, _) ->
    No;
bang(Pid, T) ->
    Pid ! T.

%% call/1

call(Request) ->
    gen_server:call(?SERVER, Request, infinity).
