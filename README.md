# KCP Erlang Port

A safe Erlang port implementation of the [KCP protocol](https://github.com/skywind3000/kcp) - A Fast and Reliable ARQ Protocol.

## Features

- **Fast & Reliable**: Implements KCP's ARQ protocol for low-latency networking
- **Safe**: Uses Erlang ports instead of NIFs for better isolation and crash safety
- **Full API**: Complete coverage of KCP protocol functions
- **OTP Ready**: Built as a proper OTP application with supervision tree

## What is KCP?

KCP is a fast and reliable ARQ (Automatic Repeat-reQuest) protocol that can achieve:
- 30%-40% lower average latency compared to TCP
- 3x reduction in maximum latency
- Better performance in lossy network conditions (WiFi, 3G/4G)

It sacrifices 10%-20% bandwidth to achieve these improvements.

## Installation

### Prerequisites

- Erlang/OTP 22 or later
- C compiler (gcc or clang)
- rebar3

### Build

```bash
# Clone the repository
git clone <your-repo-url>
cd kcp_erl

# Build with rebar3
rebar3 compile

# Or build manually
make
```

## Quick Start

### Basic Usage

```erlang
%% Start the application
application:start(kcp).

%% Create a KCP instance with conversation ID
{ok, Handle} = kcp:create(123).

%% Configure for fast mode (optional)
%% nodelay, interval, resend, nc
ok = kcp:nodelay(Handle, 1, 10, 2, 1).

%% Set window size (optional)
ok = kcp:wndsize(Handle, 128, 128).

%% Send data
ok = kcp:send(Handle, <<"Hello, KCP!">>).

%% Update KCP (should be called regularly)
Current = erlang:system_time(millisecond),
ok = kcp:update(Handle, Current).

%% Input received UDP data
ok = kcp:input(Handle, UdpData).

%% Receive processed data
case kcp:recv(Handle) of
    {ok, Data} -> io:format("Received: ~p~n", [Data]);
    {error, no_data} -> ok
end.

%% Check when next update is needed
{ok, NextTime} = kcp:check(Handle, Current).

%% Release when done
ok = kcp:release(Handle).
```

### Output Callback

KCP needs to send data over UDP. The port sends output data back to the owner process:

```erlang
%% Start KCP
{ok, Pid} = kcp:start_link().

%% You'll receive messages like this:
receive
    {kcp_output, Conv, Data} ->
        %% Send Data via UDP
        gen_udp:send(Socket, RemoteIP, RemotePort, Data)
end.
```

### Complete Example

See `examples/kcp_echo_server.erl` for a complete UDP echo server implementation.
- compile:
    - erlc -I include -o ebin examples/kcp_echo_server.erl
    - erlc -I include -o ebin examples/kcp_echo_client.erl
- run:
    - erl -pa ebin -pa _build/default/lib/kcp/ebin -noshell -eval 'application:ensure_all_started(kcp), kcp_echo_server:start(9102), io:format("KCP echo server started on 9102~n"), timer:sleep(infinity).'
    - erl -pa ebin -pa _build/default/lib/kcp/ebin -noshell -eval 'application:ensure_all_started(kcp), C = kcp_echo_client:start({127,0,0,1}, 9102, 12345), kcp_echo_client:send(<<"Hello from client">>), timer:sleep(2000), kcp_echo_client:stop(), io:format("Client done~n"), init:stop().'

## API Reference

### Core Functions

- `create(Conv)` - Create a KCP instance with conversation ID
- `release(Handle)` - Release a KCP instance
- `send(Handle, Data)` - Send data through KCP
- `recv(Handle)` - Receive data from KCP
- `input(Handle, Data)` - Input received UDP data
- `update(Handle, Current)` - Update KCP state with current timestamp (ms)
- `check(Handle, Current)` - Get next update time

### Configuration Functions

- `nodelay(Handle, Nodelay, Interval, Resend, Nc)` - Configure fast mode
  - `Nodelay`: 0=disable, 1=enable
  - `Interval`: Internal update interval (10-20ms)
  - `Resend`: Fast retransmit trigger (0=off, 2=2 ACK skips)
  - `Nc`: 0=normal flow control, 1=disable flow control

- `wndsize(Handle, SndWnd, RcvWnd)` - Set send/receive window size
- `setmtu(Handle, Mtu)` - Set Maximum Transmission Unit (default: 1400)

### Utility Functions

- `peeksize(Handle)` - Get size of next receive packet
- `waitsnd(Handle)` - Get number of packets waiting to be sent

## Configuration Modes

### Normal Mode
```erlang
kcp:nodelay(Handle, 0, 40, 0, 0).
```

### Fast Mode
```erlang
kcp:nodelay(Handle, 1, 10, 2, 1).
```

### Ultra Fast Mode (for games)
```erlang
kcp:nodelay(Handle, 1, 10, 2, 1),
kcp:wndsize(Handle, 1024, 1024),
Handle ! rx_minrto = 10.  %% Note: rx_minrto not exposed in this version
```

## Architecture

```
┌─────────────────────┐
│   Erlang Process    │
│  (Your Application) │
└──────────┬──────────┘
           │ API Calls
           ▼
┌─────────────────────┐
│   kcp.erl           │
│  (gen_server)       │
└──────────┬──────────┘
           │ Port Protocol
           ▼
┌─────────────────────┐
│   kcp_port          │
│  (C Program)        │
│  ├─ ikcp.c          │
│  └─ Port I/O        │
└─────────────────────┘
```

## Performance Tips

1. **Update Interval**: Call `update/2` regularly (every 10-20ms for best performance)
2. **Use `check/2`**: Optimize update timing by checking when next update is needed
3. **Window Size**: Increase window size for high-bandwidth scenarios
4. **MTU**: Adjust MTU based on your network (default 1400 works for most cases)
5. **Fast Mode**: Enable for real-time applications (games, live streaming)

## Comparison with TCP

| Feature | TCP | KCP Fast Mode |
|---------|-----|---------------|
| Latency | Baseline | 30-40% lower |
| Max Latency | Baseline | 3x lower |
| Bandwidth | Baseline | 10-20% higher |
| Packet Loss Recovery | Slow | Fast retransmit |
| Flow Control | Conservative | Configurable |

## License

This wrapper is provided under the MIT License.

The original KCP protocol is by [skywind3000](https://github.com/skywind3000/kcp) under MIT License.

## Credits

- Original KCP: [skywind3000/kcp](https://github.com/skywind3000/kcp)
- Erlang Port Implementation: This project

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Resources

- [KCP Wiki](https://github.com/skywind3000/kcp/wiki)
- [KCP Best Practices](https://github.com/skywind3000/kcp/wiki/KCP-Best-Practice)
- [KCP Benchmark](https://github.com/skywind3000/kcp/wiki/KCP-Benchmark)
