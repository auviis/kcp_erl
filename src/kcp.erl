%%%-------------------------------------------------------------------
%%% @doc
%%% KCP Erlang Port Wrapper
%%% 
%%% Provides a safe Erlang interface to the KCP protocol using ports.
%%% @end
%%%-------------------------------------------------------------------
-module(kcp).

-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1]).
-export([create/1, release/1]).
-export([send/2, recv/1]).
-export([update/2, check/2, flush/1]).
-export([input/2]).
-export([nodelay/5, wndsize/3, setmtu/2]).
-export([peeksize/1, waitsnd/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(CMD_CREATE, 1).
-define(CMD_RELEASE, 2).
-define(CMD_SEND, 3).
-define(CMD_RECV, 4).
-define(CMD_UPDATE, 5).
-define(CMD_CHECK, 6).
-define(CMD_FLUSH, 7).
-define(CMD_INPUT, 8).
-define(CMD_PEEKSIZE, 9).
-define(CMD_SETMTU, 10).
-define(CMD_WNDSIZE, 11).
-define(CMD_WAITSND, 12).
-define(CMD_NODELAY, 13).

-record(state, {
    port :: port(),
    owner :: pid(),
    output_callback :: function() | undefined,
    pending_calls = [] :: list(),
    buffer = <<>> :: binary()
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start the KCP port server
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link([]).

-spec start_link(list()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, [self() | Opts], []).

%% @doc Create a new KCP instance
-spec create(Conv :: non_neg_integer()) -> {ok, Handle :: integer()} | {error, term()}.
create(Conv) when is_integer(Conv), Conv >= 0 ->
    Server = get_server(),
    gen_server:call(Server, {create, Conv}, infinity).

%% @doc Release a KCP instance
-spec release(Handle :: integer()) -> ok | {error, term()}.
release(Handle) when is_integer(Handle) ->
    Server = get_server(),
    gen_server:call(Server, {release, Handle}, infinity).

%% @doc Send data through KCP
-spec send(Handle :: integer(), Data :: binary()) -> ok | {error, term()}.
send(Handle, Data) when is_integer(Handle), is_binary(Data) ->
    Server = get_server(),
    gen_server:call(Server, {send, Handle, Data}, infinity).

%% @doc Receive data from KCP
-spec recv(Handle :: integer()) -> {ok, binary()} | {error, term()}.
recv(Handle) when is_integer(Handle) ->
    Server = get_server(),
    gen_server:call(Server, {recv, Handle}, infinity).

%% @doc Update KCP state with current timestamp
-spec update(Handle :: integer(), Current :: non_neg_integer()) -> ok | {error, term()}.
update(Handle, Current) when is_integer(Handle), is_integer(Current) ->
    Server = get_server(),
    gen_server:call(Server, {update, Handle, Current}, infinity).

%% @doc Flush KCP send queue immediately
-spec flush(Handle :: integer()) -> ok | {error, term()}.
flush(Handle) when is_integer(Handle) ->
    Server = get_server(),
    gen_server:call(Server, {flush, Handle}, infinity).

%% @doc Check next update time
-spec check(Handle :: integer(), Current :: non_neg_integer()) -> {ok, non_neg_integer()} | {error, term()}.
check(Handle, Current) when is_integer(Handle), is_integer(Current) ->
    Server = get_server(),
    gen_server:call(Server, {check, Handle, Current}, infinity).

%% @doc Input received UDP packet into KCP
-spec input(Handle :: integer(), Data :: binary()) -> ok | {error, term()}.
input(Handle, Data) when is_integer(Handle), is_binary(Data) ->
    Server = get_server(),
    gen_server:call(Server, {input, Handle, Data}, infinity).

%% @doc Configure KCP nodelay parameters
-spec nodelay(Handle :: integer(), Nodelay :: integer(), Interval :: integer(), 
              Resend :: integer(), Nc :: integer()) -> ok | {error, term()}.
nodelay(Handle, Nodelay, Interval, Resend, Nc) 
  when is_integer(Handle), is_integer(Nodelay), is_integer(Interval),
       is_integer(Resend), is_integer(Nc) ->
    Server = get_server(),
    gen_server:call(Server, {nodelay, Handle, Nodelay, Interval, Resend, Nc}, infinity).

%% @doc Set window size
-spec wndsize(Handle :: integer(), SndWnd :: integer(), RcvWnd :: integer()) -> ok | {error, term()}.
wndsize(Handle, SndWnd, RcvWnd) 
  when is_integer(Handle), is_integer(SndWnd), is_integer(RcvWnd) ->
    Server = get_server(),
    gen_server:call(Server, {wndsize, Handle, SndWnd, RcvWnd}, infinity).

%% @doc Set MTU
-spec setmtu(Handle :: integer(), Mtu :: integer()) -> ok | {error, term()}.
setmtu(Handle, Mtu) when is_integer(Handle), is_integer(Mtu) ->
    Server = get_server(),
    gen_server:call(Server, {setmtu, Handle, Mtu}, infinity).

%% @doc Get peek size
-spec peeksize(Handle :: integer()) -> {ok, integer()} | {error, term()}.
peeksize(Handle) when is_integer(Handle) ->
    Server = get_server(),
    gen_server:call(Server, {peeksize, Handle}, infinity).

%% @doc Get number of packets waiting to be sent
-spec waitsnd(Handle :: integer()) -> {ok, integer()} | {error, term()}.
waitsnd(Handle) when is_integer(Handle) ->
    Server = get_server(),
    gen_server:call(Server, {waitsnd, Handle}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Owner | _Opts]) ->
    process_flag(trap_exit, true),
    PortPath = get_port_path(),
    Port = open_port({spawn, PortPath}, [binary, exit_status, stream]),
    {ok, #state{port = Port, owner = Owner}}.

handle_call({create, Conv}, From, State = #state{port = Port}) ->
    Data = <<Conv:32>>,
    send_command(Port, ?CMD_CREATE, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, create}]}};

handle_call({release, Handle}, From, State = #state{port = Port}) ->
    Data = <<Handle:32>>,
    send_command(Port, ?CMD_RELEASE, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, release}]}};

handle_call({send, Handle, Binary}, From, State = #state{port = Port}) ->
    Data = <<Handle:32, Binary/binary>>,
    send_command(Port, ?CMD_SEND, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, send}]}};

handle_call({recv, Handle}, From, State = #state{port = Port}) ->
    Data = <<Handle:32>>,
    send_command(Port, ?CMD_RECV, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, recv}]}};

handle_call({update, Handle, Current}, From, State = #state{port = Port}) ->
    Data = <<Handle:32, Current:32>>,
    send_command(Port, ?CMD_UPDATE, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, update}]}};

handle_call({flush, Handle}, From, State = #state{port = Port}) ->
    Data = <<Handle:32>>,
    send_command(Port, ?CMD_FLUSH, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, flush}]}};

handle_call({check, Handle, Current}, From, State = #state{port = Port}) ->
    Data = <<Handle:32, Current:32>>,
    send_command(Port, ?CMD_CHECK, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, check}]}};

handle_call({input, Handle, Binary}, From, State = #state{port = Port}) ->
    Data = <<Handle:32, Binary/binary>>,
    send_command(Port, ?CMD_INPUT, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, input}]}};

handle_call({nodelay, Handle, Nodelay, Interval, Resend, Nc}, From, State = #state{port = Port}) ->
    Data = <<Handle:32, Nodelay:32, Interval:32, Resend:32, Nc:32>>,
    send_command(Port, ?CMD_NODELAY, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, nodelay}]}};

handle_call({wndsize, Handle, SndWnd, RcvWnd}, From, State = #state{port = Port}) ->
    Data = <<Handle:32, SndWnd:32, RcvWnd:32>>,
    send_command(Port, ?CMD_WNDSIZE, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, wndsize}]}};

handle_call({setmtu, Handle, Mtu}, From, State = #state{port = Port}) ->
    Data = <<Handle:32, Mtu:32>>,
    send_command(Port, ?CMD_SETMTU, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, setmtu}]}};

handle_call({peeksize, Handle}, From, State = #state{port = Port}) ->
    Data = <<Handle:32>>,
    send_command(Port, ?CMD_PEEKSIZE, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, peeksize}]}};

handle_call({waitsnd, Handle}, From, State = #state{port = Port}) ->
    Data = <<Handle:32>>,
    send_command(Port, ?CMD_WAITSND, Data),
    {noreply, State#state{pending_calls = State#state.pending_calls ++ [{From, waitsnd}]}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, NewData}}, State = #state{port = Port, buffer = Buffer}) ->
    Data = <<Buffer/binary, NewData/binary>>,
    {Responses, RestBuffer} = parse_responses(Data, []),
    NewState = process_responses(Responses, State),
    {noreply, NewState#state{buffer = RestBuffer}};

handle_info({Port, {exit_status, Status}}, State = #state{port = Port}) ->
    {stop, {port_exit, Status}, State};

handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    {stop, {port_terminated, Reason}, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = Port}) ->
    catch port_close(Port),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_server() ->
    case get(kcp_server) of
        undefined ->
            {ok, Pid} = start_link(),
            put(kcp_server, Pid),
            Pid;
        Pid ->
            Pid
    end.

get_port_path() ->
    PrivDir = case code:priv_dir(kcp) of
        {error, _} ->
            % Development mode
            filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]);
        Dir ->
            Dir
    end,
    filename:join(PrivDir, "kcp_port").

send_command(Port, Cmd, Data) ->
    Len = byte_size(Data),
    Packet = <<Cmd:8, Len:32, Data/binary>>,
    port_command(Port, Packet).

reply_to_pending([{From, _Type} | Rest], Response) ->
    gen_server:reply(From, Response),
    Rest;
reply_to_pending([], _Response) ->
    [].

parse_ok_response(<<>>) ->
    ok;
parse_ok_response(<<Value:32/signed>>) ->
    {ok, Value};
parse_ok_response(Data) ->
    {ok, Data}.

%% Parse responses from stream buffer
%% Output response has different format: [Type:8, Conv:32, Len:32, Data]
parse_responses(<<1:8, Conv:32, Len:32, Rest/binary>>, Acc) when byte_size(Rest) >= Len ->
    {Payload, Remaining} = split_binary(Rest, Len),
    Response = {output, Conv, Payload},
    parse_responses(Remaining, [Response | Acc]);
%% Other responses: [Type:8, Len:32, Data]
parse_responses(<<Type:8, Len:32, Rest/binary>>, Acc) when byte_size(Rest) >= Len ->
    {Payload, Remaining} = split_binary(Rest, Len),
    Response = case Type of
        0 -> {error, binary_to_list(Payload)};  % Error
        2 -> {ok, Payload};                      % OK
        _ -> {unknown, Type, Payload}
    end,
    parse_responses(Remaining, [Response | Acc]);
parse_responses(Data, Acc) ->
    % Not enough data for complete message, keep buffer
    {lists:reverse(Acc), Data}.

%% Process parsed responses
process_responses([], State) ->
    State;
process_responses([{error, ErrorMsg} | Rest], State = #state{pending_calls = Pending}) ->
    NewPending = reply_to_pending(Pending, {error, list_to_atom(ErrorMsg)}),
    process_responses(Rest, State#state{pending_calls = NewPending});
process_responses([{output, Conv, Data} | Rest], State = #state{owner = Owner}) ->
    Owner ! {kcp_output, Conv, Data},
    process_responses(Rest, State);
process_responses([{ok, Payload} | Rest], State = #state{pending_calls = Pending}) ->
    Response = parse_ok_response(Payload),
    NewPending = reply_to_pending(Pending, Response),
    process_responses(Rest, State#state{pending_calls = NewPending});
process_responses([_ | Rest], State) ->
    process_responses(Rest, State).
