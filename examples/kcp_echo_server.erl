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
    sessions = #{} :: map(),      % {IP, Port} => {HandleOrUndefined, Conv, LastActivity, WorkerPid}
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
            schedule_hello_send(),
            
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
        {_HandleOrUndef, _Conv, _LastActivity, Pid} when is_pid(Pid) ->
            Pid ! {send, Message},
            {reply, ok, State};
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
    NewState = handle_udp(Socket, IP, Port, Data, State),
    {noreply, NewState};

%% Session worker reported activity; update last-activity timestamp
handle_info({session_activity, Conv}, State = #state{conv_to_key = ConvMap, sessions = Sessions}) ->
    case maps:get(Conv, ConvMap, undefined) of
        {IP, Port} ->
            Key = {IP, Port},
            case maps:get(Key, Sessions, undefined) of
                {Handle, Conv, _OldActivity, Pid} ->
                    Now = erlang:monotonic_time(millisecond),
                    NewSessions = maps:put(Key, {Handle, Conv, Now, Pid}, Sessions),
                    {noreply, State#state{sessions = NewSessions}};
                _ ->
                    {noreply, State}
            end;
        undefined ->
            {noreply, State}
    end;

%% NOTE: when workers own KCP handles they will receive {kcp_output,...}
%% and send UDP themselves. Server no longer handles kcp_output.

handle_info({flush_kcp, _Handle}, State) ->
    %% Workers flush their own handles; ignore server-side flush requests
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

handle_info(send_hello, State) ->
    %% Send scheduled "hello" to all active sessions (workers will handle kcp send)
    NewState = send_hello_to_all(State),
    schedule_hello_send(),
    {noreply, NewState};

%% Worker exit notification: remove session and conv mapping
handle_info({worker_exit, Conv}, State = #state{conv_to_key = ConvMap, sessions = Sessions}) ->
    case maps:get(Conv, ConvMap, undefined) of
        {IP, Port} ->
            Key = {IP, Port},
            NewSessions = maps:remove(Key, Sessions),
            NewConv = maps:remove(Conv, ConvMap),
            {noreply, State#state{sessions = NewSessions, conv_to_key = NewConv}};
        undefined ->
            {noreply, State}
    end;

%% Monitor down for worker processes: cleanup corresponding session
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #state{monitors = Monitors, sessions = Sessions, conv_to_key = ConvMap}) ->
    case lists:keyfind(Ref, 2, maps:to_list(Monitors)) of
        {Key, _} ->
            case maps:get(Key, Sessions, undefined) of
                {_, Conv, _LastActivity, _} ->
                    NewSessions = maps:remove(Key, Sessions),
                    NewConv = maps:remove(Conv, ConvMap),
                    NewMonitors = maps:remove(Key, Monitors),
                    {noreply, State#state{sessions = NewSessions, conv_to_key = NewConv, monitors = NewMonitors}};
                _ -> {noreply, State}
            end;
        false -> {noreply, State}
    end;

handle_info(_Info, State) ->
    io:format("Warning: Unknown message: ~p~n", [_Info]),
    {noreply, State}.

%% @private
terminate(_Reason, #state{socket = Socket, sessions = Sessions}) ->
    %% Stop worker processes and release any server-owned handles (if present)
    maps:fold(
        fun(_Key, {HandleOrUndef, _Conv, _LastActivity, Pid}, Acc) ->
            case is_pid(Pid) of
                true -> Pid ! stop;
                false -> ok
            end,
            case HandleOrUndef of
                undefined -> ok;
                _ -> catch kcp:release(HandleOrUndef)
            end,
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

handle_udp(Socket, IP, Port, Data, State = #state{sessions = Sessions}) ->
    Key = {IP, Port},

    case maps:get(Key, Sessions, undefined) of
        undefined ->
            %% New session - extract Conv from the KCP packet
            case extract_conv(Data) of
                {ok, Conv} ->
                    io:format("New session from ~p:~p (Conv: ~p)~n", [IP, Port, Conv]),

                    %% Spawn a dedicated worker to handle this session; worker will create its own handle
                    Worker = spawn(fun() -> session_worker_init(Conv, Data, IP, Port, Socket, self()) end),
                    Ref = erlang:monitor(process, Worker),

                    %% Store session with timestamp and worker pid (handle is owned by worker)
                    Now = erlang:monotonic_time(millisecond),
                    NewSessions = maps:put(Key, {undefined, Conv, Now, Worker}, Sessions),
                    NewConvMap = maps:put(Conv, Key, State#state.conv_to_key),
                    NewMonitors = maps:put(Key, Ref, State#state.monitors),
                    State#state{sessions = NewSessions, conv_to_key = NewConvMap, monitors = NewMonitors};
                {error, invalid_packet} ->
                    io:format("Warning: Received invalid KCP packet from ~p:~p~n", [IP, Port]),
                    State
            end;

        {_HandleOrUndef, Conv, _LastActivity, Worker} ->
            %% Existing session - forward raw UDP data to worker
            Worker ! {input, Data, IP, Port},
            %% Update last activity timestamp
            Now = erlang:monotonic_time(millisecond),
            NewSessions = maps:put(Key, {undefined, Conv, Now, Worker}, Sessions),
            State#state{sessions = NewSessions}
    end.
 

%% Worker that handles a single session: receives forwarded UDP packets,
%% inputs them into KCP, drains received messages and echoes them back.
session_worker_init(Conv, FirstData, IP, Port, Socket, ServerPid) ->
    %% Create KCP handle in worker process (handles are process-local in this kcp lib)
    case kcp:create(Conv) of
        {ok, Handle} ->
            ok = kcp:nodelay(Handle, 1, 10, 2, 1),
            ok = kcp:wndsize(Handle, 128, 128),
            ok = kcp:setmtu(Handle, 1400),
            %% If there is initial data, input it
            (case FirstData of
                 undefined -> ok;
                 _ -> (case kcp:input(Handle, FirstData) of ok -> ok; {error, R} -> io:format("Worker input error init: ~p~n", [R]) end)
            end),
            %% Drain any immediate application data
            drain_recv(Handle, IP, Port, ServerPid, Socket, Conv),
            session_worker_loop(Handle, Conv, Socket, IP, Port, ServerPid);
        {error, Reason} ->
            io:format("Worker failed to create handle for conv ~p - ~p~n", [Conv, Reason]),
            ServerPid ! {worker_exit, Conv},
            exit(Reason)
    end.

session_worker_loop(Handle, Conv, Socket, IP, Port, ServerPid) ->
    receive
        {input, Data, _IP, _Port} ->
            case kcp:input(Handle, Data) of
                ok ->
                    drain_recv(Handle, IP, Port, ServerPid, Socket, Conv),
                    ServerPid ! {session_activity, Conv},
                    session_worker_loop(Handle, Conv, Socket, IP, Port, ServerPid);
                {error, Reason} ->
                    io:format("Worker: kcp:input error for conv ~p - ~p~n", [Conv, Reason]),
                    session_worker_loop(Handle, Conv, Socket, IP, Port, ServerPid)
            end;
        {send, Msg} when is_binary(Msg) ->
            case kcp:send(Handle, Msg) of
                ok -> kcp:flush(Handle);
                {error, R} -> io:format("Worker: send error ~p~n", [R])
            end,
            session_worker_loop(Handle, Conv, Socket, IP, Port, ServerPid);
        {kcp_output, _Conv, OutputData} ->
            gen_udp:send(Socket, IP, Port, OutputData),
            io:format("Worker sent ~p bytes to ~p:~p (Conv: ~p)~n", [byte_size(OutputData), IP, Port, Conv]),
            session_worker_loop(Handle, Conv, Socket, IP, Port, ServerPid);
        stop ->
            kcp:release(Handle),
            ServerPid ! {worker_exit, Conv},
            ok
    after 10 ->
        %% Periodic update and dead-link check
        Current = erlang:system_time(millisecond) band 16#FFFFFFFF,
        catch kcp:update(Handle, Current),
        case catch kcp:waitsnd(Handle) of
            {ok, WaitSnd} when is_integer(WaitSnd), WaitSnd > ?DEAD_LINK_THRESHOLD ->
                io:format("Worker: Dead link for conv ~p, queue=~p~n", [Conv, WaitSnd]),
                kcp:release(Handle),
                ServerPid ! {worker_exit, Conv},
                exit(dead_link);
            _ -> ok
        end,
        session_worker_loop(Handle, Conv, Socket, IP, Port, ServerPid)
    end.

drain_recv(Handle, IP, Port, ServerPid, Socket, Conv) ->
    case kcp:recv(Handle) of
        {ok, RecvData} ->
            io:format("Worker Received from ~p:~p: ~p~n", [IP, Port, RecvData]),
            case kcp:send(Handle, RecvData) of
                ok -> kcp:flush(Handle);
                {error, Reason} -> io:format("Worker: Failed to queue echo: ~p~n", [Reason])
            end,
            drain_recv(Handle, IP, Port, ServerPid, Socket, Conv);
        {error, no_data} ->
            ok
    end.

update_all_sessions(State = #state{sessions = _Sessions}) ->
    %% Workers own handles and perform their own updates; server no-op here
    State.

schedule_update() ->
    erlang:send_after(10, self(), update_kcp).

schedule_timeout_check() ->
    erlang:send_after(5000, self(), check_timeouts).

%% Schedule hello every 10 seconds
schedule_hello_send() ->
    erlang:send_after(10000, self(), send_hello).

%% Send "hello" to all active sessions
send_hello_to_all(State = #state{sessions = Sessions}) ->
    maps:fold(
        fun({IP, Port}, {_Handle, _Conv, _LastActivity, Pid}, Acc) ->
            case is_pid(Pid) of
                true ->
                    Pid ! {send, <<"hello">>},
                    io:format("Scheduled hello to ~p:~p (worker)~n", [IP, Port]),
                    Acc;
                false ->
                    Acc
            end
        end,
        State,
        Sessions
    ).

cleanup_inactive_sessions(State = #state{sessions = Sessions, conv_to_key = ConvToKey}) ->
    Now = erlang:monotonic_time(millisecond),
    
    {NewSessions, NewConvToKey} = maps:fold(
        fun(Key, {Handle, Conv, LastActivity, Pid}, {AccSessions, AccConvToKey}) ->
            Age = Now - LastActivity,
            if
                Age > ?SESSION_TIMEOUT ->
                    {IP, Port} = Key,
                    io:format("Session timeout: ~p:~p (Conv: ~p, inactive for ~p ms)~n",
                             [IP, Port, Conv, Age]),
                    %% Let worker release its handle; ask it to stop instead of killing it
                    (case is_pid(Pid) of true -> Pid ! stop; false -> ok end),
                    {AccSessions, maps:remove(Conv, AccConvToKey)};
                true ->
                    {maps:put(Key, {Handle, Conv, LastActivity, Pid}, AccSessions),
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
        fun(Key, {Handle, Conv, LastActivity, Pid}, {AccSessions, AccConvToKey}) ->
            case Handle of
                undefined ->
                    %% Worker owns handle; rely on worker health/notifications
                    {maps:put(Key, {Handle, Conv, LastActivity, Pid}, AccSessions), AccConvToKey};
                _ ->
                    case catch kcp:waitsnd(Handle) of
                        {ok, WaitSnd} when WaitSnd > ?DEAD_LINK_THRESHOLD ->
                            {IP, Port} = Key,
                            io:format("Dead link detected: ~p:~p (Conv: ~p, queue: ~p packets)~n",
                                     [IP, Port, Conv, WaitSnd]),
                            (case is_pid(Pid) of true -> Pid ! stop; false -> ok end),
                            {AccSessions, maps:remove(Conv, AccConvToKey)};
                        {ok, _} ->
                            {maps:put(Key, {Handle, Conv, LastActivity, Pid}, AccSessions), AccConvToKey};
                        _ ->
                            {IP, Port} = Key,
                            io:format("Invalid handle for ~p:~p (Conv: ~p), removing session~n",
                                     [IP, Port, Conv]),
                            (case is_pid(Pid) of true -> Pid ! stop; false -> ok end),
                            {AccSessions, maps:remove(Conv, AccConvToKey)}
                    end
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
