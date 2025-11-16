%%%-------------------------------------------------------------------
%%% @doc
%%% KCP Top Level Supervisor
%%% @end
%%%-------------------------------------------------------------------
-module(kcp_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 10},

    %% No children by default - KCP instances are created on demand
    ChildSpecs = [],

    {ok, {SupFlags, ChildSpecs}}.
