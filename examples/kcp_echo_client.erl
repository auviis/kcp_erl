%%%-------------------------------------------------------------------
%%% @doc
%%% KCP Echo Client Example
%%% 
%%% A simple client that sends messages to KCP echo server.
%%% c("examples/kcp_echo_client.erl").
%%% kcp_echo_client:start({127,0,0,1}, 9102, 12345).
%%% kcp_echo_client:send(<<"Test 1">>).
%%% @end
%%%-------------------------------------------------------------------
-module(kcp_echo_client).

-export([start/3, send/1, stop/0]).
-export([init/3, loop/1]).

-record(state, {
    socket :: gen_udp:socket(),
    kcp_server :: pid(),
    handle :: integer(),
    conv :: non_neg_integer(),
    remote_ip :: inet:ip_address(),
    remote_port :: inet:port_number()
}).

%% @doc Start the echo client
start(ServerIP, ServerPort, Conv) ->
    spawn(?MODULE, init, [ServerIP, ServerPort, Conv]).

%% @doc Send a message
send(Message) when is_binary(Message) ->
    whereis(?MODULE) ! {send, Message},
    ok.

%% @doc Stop the client
stop() ->
    whereis(?MODULE) ! stop,
    ok.

init(ServerIP, ServerPort, Conv) ->
    register(?MODULE, self()),
    
    %% Start KCP application
    application:ensure_all_started(kcp),
    
    %% Start KCP server
    {ok, KcpServer} = kcp:start_link(),
    
    %% Create KCP instance
    {ok, Handle} = kcp:create(Conv),
    
    %% Configure for fast mode
    ok = kcp:nodelay(Handle, 1, 10, 2, 1),
    ok = kcp:wndsize(Handle, 128, 128),
    
    %% Open UDP socket
    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),
    
    io:format("KCP Client started (Conv: ~p, Handle: ~p)~n", [Conv, Handle]),
    io:format("Connecting to ~p:~p~n", [ServerIP, ServerPort]),
    
    State = #state{
        socket = Socket,
        kcp_server = KcpServer,
        handle = Handle,
        conv = Conv,
        remote_ip = ServerIP,
        remote_port = ServerPort
    },
    
    %% Schedule KCP updates
    schedule_update(),
    
    loop(State).

loop(State = #state{socket = Socket, handle = Handle, 
                    remote_ip = IP, remote_port = Port}) ->
    receive
        %% User wants to send a message
        {send, Message} ->
            ok = kcp:send(Handle, Message),
            io:format("Sent: ~p~n", [Message]),
            %% Trigger immediate flush
            self() ! {flush_kcp, Handle},
            loop(State);
        
        %% Received UDP packet from server
        {udp, Socket, IP, Port, Data} ->
            case kcp:input(Handle, Data) of
                ok ->
                    process_recv(Handle);
                {error, Reason} ->
                    io:format("Warning: KCP input failed: ~p~n", [Reason])
            end,
            loop(State);
        
        %% KCP wants to output data
        {kcp_output, _Conv, OutputData} ->
            gen_udp:send(Socket, IP, Port, OutputData),
            io:format("Sent ~p bytes to server~n", [byte_size(OutputData)]),
            loop(State);
        
        %% Flush KCP session (trigger immediate send)
        {flush_kcp, FlushHandle} ->
            kcp:flush(FlushHandle),
            loop(State);
        
        %% Timer to update KCP
        update_kcp ->
            Current = erlang:system_time(millisecond) band 16#FFFFFFFF,
            kcp:update(Handle, Current),
            schedule_update(),
            loop(State);
        
        stop ->
            cleanup(State),
            ok;
        
        Other ->
            io:format("Unknown message: ~p~n", [Other]),
            loop(State)
    end.

process_recv(Handle) ->
    case kcp:recv(Handle) of
        {ok, Data} ->
            io:format("Received echo: ~p~n", [Data]),
            process_recv(Handle);
        {error, no_data} ->
            ok
    end.

schedule_update() ->
    erlang:send_after(10, self(), update_kcp).

cleanup(#state{socket = Socket, handle = Handle}) ->
    kcp:release(Handle),
    gen_udp:close(Socket),
    unregister(?MODULE).
