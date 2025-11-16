%%%-------------------------------------------------------------------
%%% @doc
%%% KCP Echo Server Example (gen_server implementation)
%%% 
%%% A simple UDP echo server using KCP for reliable transmission.
%%% c("examples/kcp_echo_server.erl").
%%% kcp_echo_server:start(9102).
%%% @end
%%%-------------------------------------------------------------------
-module(kcp_echo_server).

-behaviour(gen_server).

%% API
-export([start_link/1, start/1, stop/0, send_message/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(SESSION_TIMEOUT, 30000).  % 30 seconds timeout
-define(DEAD_LINK_THRESHOLD, 20).  % Max retransmit attempts before considering dead

-record(state, {
    socket :: gen_udp:socket(),
    kcp_server :: pid(),
    sessions = #{} :: map(),      % {IP, Port} => {Handle, Conv, LastActivity}
    conv_to_key = #{} :: map(),   % Conv => {IP, Port}
    monitors = #{} :: map()       % {IP, Port} => MonitorRef (for future use)
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start the server with supervision
-spec start_link(Port :: inet:port_number()) -> {ok, pid()} | {error, term()}.
start_link(Port) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port], []).

%% @doc Start the server without supervision
-spec start(Port :: inet:port_number()) -> {ok, pid()} | {error, term()}.
start(Port) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [Port], []).

%% @doc Stop the server
-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER).

%% @doc Send a message to a specific client
-spec send_message(IP :: inet:ip_address(), Port :: inet:port_number(), Message :: binary()) -> ok | {error, term()}.
send_message(IP, Port, Message) ->
    gen_server:call(?SERVER, {send_message, IP, Port, Message}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([Port]) ->
    %% Start KCP application
    application:ensure_all_started(kcp),
    
    %% Start KCP server
    {ok, KcpServer} = kcp:start_link(),
    
    %% Open UDP socket
    case gen_udp:open(Port, [binary, {active, true}]) of
        {ok, Socket} ->
            io:format("KCP Echo Server listening on port ~p~n", [Port]),
            
            %% Schedule periodic tasks
            schedule_update(),
            schedule_timeout_check(),
            
            {ok, #state{
                socket = Socket,
                kcp_server = KcpServer,
                sessions = #{},
                conv_to_key = #{},
                monitors = #{}
            }};
        {error, Reason} ->
            {stop, {socket_error, Reason}}
    end.

%% @private
handle_call({send_message, IP, Port, Message}, _From, State) ->
    Key = {IP, Port},
    case maps:get(Key, State#state.sessions, undefined) of
        {Handle, _Conv, _LastActivity} ->
            case kcp:send(Handle, Message) of
                ok ->
                    self() ! {flush_kcp, Handle},
                    {reply, ok, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        undefined ->
            {reply, {error, no_session}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({udp, Socket, IP, Port, Data}, State = #state{socket = Socket}) ->
    NewState = handle_udp(IP, Port, Data, State),
    {noreply, NewState};

handle_info({kcp_output, Conv, OutputData}, State = #state{socket = Socket}) ->
    case maps:get(Conv, State#state.conv_to_key, undefined) of
        {IP, Port} ->
            gen_udp:send(Socket, IP, Port, OutputData),
            io:format("Sent ~p bytes to ~p:~p (Conv: ~p)~n", 
                     [byte_size(OutputData), IP, Port, Conv]),
            {noreply, State};
        undefined ->
            io:format("Warning: Output for unknown conv ~p~n", [Conv]),
            {noreply, State}
    end;

handle_info({flush_kcp, Handle}, State) ->
    kcp:flush(Handle),
    {noreply, State};

handle_info(update_kcp, State) ->
    NewState = update_all_sessions(State),
    schedule_update(),
    {noreply, NewState};

handle_info(check_timeouts, State) ->
    State1 = cleanup_inactive_sessions(State),
    State2 = check_dead_links(State1),
    schedule_timeout_check(),
    {noreply, State2};

handle_info(_Info, State) ->
    io:format("Warning: Unknown message: ~p~n", [_Info]),
    {noreply, State}.

%% @private
terminate(_Reason, #state{socket = Socket, sessions = Sessions}) ->
    %% Release all KCP instances
    maps:fold(
        fun(_Key, {Handle, _Conv, _LastActivity}, Acc) ->
            kcp:release(Handle),
            Acc
        end,
        ok,
        Sessions
    ),
    %% Close socket
    gen_udp:close(Socket),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_udp(IP, Port, Data, State = #state{sessions = Sessions}) ->
    Key = {IP, Port},
    
    case maps:get(Key, Sessions, undefined) of
        undefined ->
            %% New session - extract Conv from the KCP packet
            case extract_conv(Data) of
                {ok, Conv} ->
                    {ok, Handle} = kcp:create(Conv),
                    
                    %% Configure KCP for fast mode with dead link detection
                    ok = kcp:nodelay(Handle, 1, 10, 2, 1),
                    ok = kcp:wndsize(Handle, 128, 128),
                    ok = kcp:setmtu(Handle, 1400),
                    
                    io:format("New session from ~p:~p (Conv: ~p, Handle: ~p)~n", 
                             [IP, Port, Conv, Handle]),
                    
                    %% Process the data
                    case kcp:input(Handle, Data) of
                        ok ->
                            process_kcp_recv(Handle, IP, Port),
                            %% Store session with timestamp
                            Now = erlang:monotonic_time(millisecond),
                            NewSessions = maps:put(Key, {Handle, Conv, Now}, Sessions),
                            NewConvMap = maps:put(Conv, Key, State#state.conv_to_key),
                            State#state{sessions = NewSessions, conv_to_key = NewConvMap};
                        {error, Reason} ->
                            io:format("Warning: Failed to input data for new session ~p:~p - ~p~n", 
                                     [IP, Port, Reason]),
                            kcp:release(Handle),
                            State
                    end;
                {error, invalid_packet} ->
                    io:format("Warning: Received invalid KCP packet from ~p:~p~n", [IP, Port]),
                    State
            end;
        
        {Handle, Conv, _LastActivity} ->
            %% Existing session - input data to KCP
            case kcp:input(Handle, Data) of
                ok ->
                    process_kcp_recv(Handle, IP, Port),
                    %% Update last activity timestamp
                    Now = erlang:monotonic_time(millisecond),
                    NewSessions = maps:put(Key, {Handle, Conv, Now}, Sessions),
                    State#state{sessions = NewSessions};
                {error, Reason} ->
                    io:format("Warning: Failed to input data for ~p:~p - ~p~n", 
                             [IP, Port, Reason]),
                    State
            end
    end.

process_kcp_recv(Handle, IP, Port) ->
    case kcp:recv(Handle) of
        {ok, RecvData} ->
            io:format("Received from ~p:~p: ~p~n", [IP, Port, RecvData]),
            %% Echo back
            case kcp:send(Handle, RecvData) of
                ok ->
                    io:format("Queued echo for ~p:~p (~p bytes)~n", [IP, Port, byte_size(RecvData)]),
                    self() ! {flush_kcp, Handle};
                {error, SendErr} ->
                    io:format("Warning: Failed to queue echo: ~p~n", [SendErr])
            end,
            %% Check for more data
            process_kcp_recv(Handle, IP, Port);
        {error, no_data} ->
            ok
    end.

update_all_sessions(State = #state{sessions = Sessions}) ->
    Current = erlang:system_time(millisecond) band 16#FFFFFFFF,
    
    maps:fold(
        fun(_Key, {Handle, _Conv, _LastActivity}, Acc) ->
            kcp:update(Handle, Current),
            Acc
        end,
        State,
        Sessions
    ).

schedule_update() ->
    erlang:send_after(10, self(), update_kcp).

schedule_timeout_check() ->
    erlang:send_after(5000, self(), check_timeouts).

cleanup_inactive_sessions(State = #state{sessions = Sessions, conv_to_key = ConvToKey}) ->
    Now = erlang:monotonic_time(millisecond),
    
    {NewSessions, NewConvToKey} = maps:fold(
        fun(Key, {Handle, Conv, LastActivity}, {AccSessions, AccConvToKey}) ->
            Age = Now - LastActivity,
            if
                Age > ?SESSION_TIMEOUT ->
                    {IP, Port} = Key,
                    io:format("Session timeout: ~p:~p (Conv: ~p, inactive for ~p ms)~n",
                             [IP, Port, Conv, Age]),
                    kcp:release(Handle),
                    {AccSessions, maps:remove(Conv, AccConvToKey)};
                true ->
                    {maps:put(Key, {Handle, Conv, LastActivity}, AccSessions),
                     AccConvToKey}
            end
        end,
        {#{}, ConvToKey},
        Sessions
    ),
    
    State#state{sessions = NewSessions, conv_to_key = NewConvToKey}.

%% Check for dead links by examining send queue buildup
check_dead_links(State = #state{sessions = Sessions, conv_to_key = ConvToKey}) ->
    {NewSessions, NewConvToKey} = maps:fold(
        fun(Key, {Handle, Conv, LastActivity}, {AccSessions, AccConvToKey}) ->
            case kcp:waitsnd(Handle) of
                {ok, WaitSnd} when WaitSnd > ?DEAD_LINK_THRESHOLD ->
                    %% Send queue is building up, likely a dead connection
                    {IP, Port} = Key,
                    io:format("Dead link detected: ~p:~p (Conv: ~p, queue: ~p packets)~n",
                             [IP, Port, Conv, WaitSnd]),
                    kcp:release(Handle),
                    {AccSessions, maps:remove(Conv, AccConvToKey)};
                {ok, _} ->
                    %% Connection healthy
                    {maps:put(Key, {Handle, Conv, LastActivity}, AccSessions),
                     AccConvToKey};
                {error, _} ->
                    %% Handle invalid, remove session
                    {IP, Port} = Key,
                    io:format("Invalid handle for ~p:~p (Conv: ~p), removing session~n",
                             [IP, Port, Conv]),
                    {AccSessions, maps:remove(Conv, AccConvToKey)}
            end
        end,
        {#{}, ConvToKey},
        Sessions
    ),
    
    State#state{sessions = NewSessions, conv_to_key = NewConvToKey}.

%% Extract conversation ID from KCP packet
%% KCP packet format: [conv(4), cmd(1), frg(1), wnd(2), ts(4), sn(4), una(4), len(4), data...]
extract_conv(<<Conv:32/little, _Rest/binary>>) when byte_size(_Rest) >= 20 ->
    {ok, Conv};
extract_conv(_) ->
    {error, invalid_packet}.
