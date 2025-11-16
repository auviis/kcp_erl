%%%-------------------------------------------------------------------
%%% @doc
%%% KCP Echo Server Example
%%% 
%%% A simple UDP echo server using KCP for reliable transmission.
%%% @end
%%%-------------------------------------------------------------------
-module(kcp_echo_server).

-export([start/1, stop/0]).
-export([init/1, loop/1]).

-define(DEFAULT_PORT, 9999).

-record(state, {
    socket :: gen_udp:socket(),
    kcp_server :: pid(),
    sessions = #{} :: map(),      % {IP, Port} => {Handle, Conv, LastActivity}
    conv_to_key = #{} :: map(),   % Conv => {IP, Port}
    monitors = #{} :: map()       % {IP, Port} => MonitorRef (for future use)
}).

-define(SESSION_TIMEOUT, 30000).  % 30 seconds timeout
-define(DEAD_LINK_THRESHOLD, 20).  % Max retransmit attempts before considering dead

%% @doc Start the echo server
start(Port) ->
    spawn(?MODULE, init, [Port]).

%% @doc Stop the echo server
stop() ->
    exit(whereis(?MODULE), shutdown).

init(Port) ->
    register(?MODULE, self()),
    
    %% Start KCP application
    application:ensure_all_started(kcp),
    
    %% Start KCP server
    {ok, KcpServer} = kcp:start_link(),
    
    %% Open UDP socket
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),
    
    io:format("KCP Echo Server listening on port ~p~n", [Port]),
    
    State = #state{
        socket = Socket,
        kcp_server = KcpServer,
        sessions = #{}
    },
    
    %% Start timeout checker
    schedule_timeout_check(),
    
    loop(State).

loop(State = #state{socket = Socket}) ->
    receive
        %% Received UDP packet
        {udp, Socket, IP, Port, Data} ->
            NewState = handle_udp(IP, Port, Data, State),
            loop(NewState);
        
        %% KCP wants to output data
        {kcp_output, Conv, OutputData} ->
            %% Find session by Conv and send data
            case find_session_by_conv(Conv, State#state.conv_to_key) of
                {ok, {IP, Port}} ->
                    gen_udp:send(Socket, IP, Port, OutputData),
                    io:format("Sent ~p bytes to ~p:~p (Conv: ~p)~n", 
                             [byte_size(OutputData), IP, Port, Conv]);
                error ->
                    io:format("Warning: Output for unknown conv ~p~n", [Conv])
            end,
            loop(State);
        
        %% Flush KCP session (trigger immediate send)
        {flush_kcp, Handle} ->
            kcp:flush(Handle),
            loop(State);
        
        %% Timer to update KCP sessions
        update_kcp ->
            NewState = update_all_sessions(State),
            schedule_update(),
            loop(NewState);
        
        %% Check for timed out sessions
        check_timeouts ->
            NewState = cleanup_inactive_sessions(State),
            NewState2 = check_dead_links(NewState),
            schedule_timeout_check(),
            loop(NewState2);
        
        stop ->
            io:format("Client stopped~n"),
            cleanup(State),
            ok;
        
        Other ->
            io:format("Warning: Unknown message: ~p~n", [Other]),
            loop(State)
    end.

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
                    %% Set dead link: 20 retries * 10ms interval = ~200ms to detect dead link
                    ok = kcp:setmtu(Handle, 1400),
                    
                    io:format("New session from ~p:~p (Conv: ~p, Handle: ~p)~n", 
                             [IP, Port, Conv, Handle]),
                    
                    %% Process the data
                    case kcp:input(Handle, Data) of
                        ok ->
                            process_kcp_recv(Handle, IP, Port),
                            %% Schedule KCP updates
                            schedule_update(),
                            %% Store session with timestamp
                            Now = erlang:monotonic_time(millisecond),
                            NewSessions = maps:put(Key, {Handle, Conv, Now}, Sessions),
                            NewConvMap = maps:put(Conv, Key, State#state.conv_to_key),
                            State#state{sessions = NewSessions, conv_to_key = NewConvMap};
                        {error, Reason} ->
                            io:format("Warning: Failed to input data for new session ~p:~p - ~p~n", 
                                     [IP, Port, Reason]),
                            io:format("  Data (first 32 bytes): ~p~n", [binary:part(Data, 0, min(32, byte_size(Data)))]),
                            %% Release the handle since we couldn't process the data
                            kcp:release(Handle),
                            State
                    end;
                {error, invalid_packet} ->
                    io:format("Warning: Received invalid KCP packet from ~p:~p~n", [IP, Port]),
                    io:format("  Data (first 32 bytes): ~p~n", [binary:part(Data, 0, min(32, byte_size(Data)))]),
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
                    %% Keep the session alive, might be temporary corruption
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
                    %% Trigger immediate flush by sending ourselves a flush message
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

generate_conv() ->
    erlang:unique_integer([positive]) band 16#FFFFFFFF.

find_session_by_conv(Conv, ConvToKey) ->
    maps:find(Conv, ConvToKey).

cleanup(#state{socket = Socket, sessions = Sessions}) ->
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
    gen_udp:close(Socket).
