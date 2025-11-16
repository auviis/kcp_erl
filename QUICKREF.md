# KCP Erlang Port - Quick Reference

## Project Structure

```
kcp_erl/
├── c_src/              # C source code
│   ├── ikcp.h          # KCP header (from upstream)
│   ├── ikcp.c          # KCP implementation (from upstream)
│   └── kcp_port.c      # Erlang port wrapper
├── src/                # Erlang source code
│   ├── kcp.erl         # Main API module
│   ├── kcp_app.erl     # OTP application
│   ├── kcp_sup.erl     # OTP supervisor
│   └── kcp.app.src     # Application resource file
├── examples/           # Example code
│   ├── kcp_echo_server.erl
│   └── kcp_echo_client.erl
├── test/               # Test code
│   └── kcp_tests.erl
├── priv/               # Compiled binaries (created on build)
├── Makefile            # Manual build
├── rebar.config        # Rebar3 configuration
├── build.sh            # Build script
└── README.md           # Documentation
```

## Build Commands

```bash
# Clean
make clean
# or
rebar3 clean

# Build
make
# or
rebar3 compile

# Test
rebar3 eunit

# Start shell
rebar3 shell
```

## API Quick Reference

### Creating/Releasing KCP

```erlang
{ok, Handle} = kcp:create(ConvId).
ok = kcp:release(Handle).
```

### Sending/Receiving Data

```erlang
ok = kcp:send(Handle, <<"data">>).
{ok, Data} = kcp:recv(Handle).
{error, no_data} = kcp:recv(Handle).
```

### Input/Output

```erlang
% Input UDP data
ok = kcp:input(Handle, UdpPacket).

% Handle output in your process
receive
    {kcp_output, Conv, Data} ->
        gen_udp:send(Socket, IP, Port, Data)
end.
```

### Update Loop

```erlang
% Get current time in milliseconds
Current = erlang:system_time(millisecond) band 16#FFFFFFFF.

% Update KCP
ok = kcp:update(Handle, Current).

% Check when next update needed
{ok, NextTime} = kcp:check(Handle, Current).
```

### Configuration

```erlang
% Fast mode: nodelay, interval, resend, nc
kcp:nodelay(Handle, 1, 10, 2, 1).

% Window size: send_window, recv_window
kcp:wndsize(Handle, 128, 128).

% MTU
kcp:setmtu(Handle, 1400).
```

### Utilities

```erlang
{ok, Size} = kcp:peeksize(Handle).  % -1 if no data
{ok, Count} = kcp:waitsnd(Handle).  % packets waiting
```

## Port Protocol

The port uses a simple binary protocol:

### Command Format (Erlang -> Port)
```
[Cmd:8, Len:32, Data:Len]
```

### Response Format (Port -> Erlang)
```
Error:  [0, Len:32, ErrorMsg:Len]
Output: [1, Conv:32, Len:32, Data:Len]
OK:     [2, Len:32, Data:Len]
```

## Command Codes

```c
#define CMD_CREATE   1   // Create KCP instance
#define CMD_RELEASE  2   // Release KCP instance
#define CMD_SEND     3   // Send data
#define CMD_RECV     4   // Receive data
#define CMD_UPDATE   5   // Update KCP state
#define CMD_CHECK    6   // Check next update time
#define CMD_INPUT    7   // Input UDP packet
#define CMD_PEEKSIZE 8   // Get peek size
#define CMD_SETMTU   9   // Set MTU
#define CMD_WNDSIZE  10  // Set window size
#define CMD_WAITSND  11  // Get wait send count
#define CMD_NODELAY  12  // Configure nodelay
```

## Common Patterns

### Server Pattern

```erlang
handle_udp(IP, Port, Data) ->
    Key = {IP, Port},
    Handle = get_or_create_kcp(Key),
    kcp:input(Handle, Data),
    process_all_recv(Handle),
    schedule_update().

process_all_recv(Handle) ->
    case kcp:recv(Handle) of
        {ok, Data} ->
            handle_data(Data),
            process_all_recv(Handle);
        {error, no_data} ->
            ok
    end.
```

### Client Pattern

```erlang
init() ->
    {ok, Handle} = kcp:create(Conv),
    kcp:nodelay(Handle, 1, 10, 2, 1),
    schedule_update(),
    {ok, Handle}.

schedule_update() ->
    erlang:send_after(10, self(), update_kcp).

handle_update() ->
    Current = erlang:system_time(millisecond) band 16#FFFFFFFF,
    kcp:update(Handle, Current),
    schedule_update().
```

## Debugging

### Enable verbose output

```erlang
% In C port, add debug prints to stderr:
fprintf(stderr, "Debug: %s\n", msg);
```

### Monitor port

```erlang
% Get port info
{ok, Pid} = kcp:start_link(),
{state, Port, _, _, _} = sys:get_state(Pid),
erlang:port_info(Port).
```

## Performance Tips

1. **Update frequently**: 10-20ms for real-time apps
2. **Use check()**: Avoid unnecessary updates
3. **Batch recv()**: Call until no_data
4. **Configure properly**: Use fast mode for low latency
5. **Monitor waitsnd()**: Detect congestion

## Troubleshooting

### Port crashes
- Check stderr output
- Verify C code compilation
- Test with simple create/release

### No data received
- Verify input() is called with UDP data
- Check update() is being called regularly
- Ensure output callback is sending data

### High latency
- Enable fast mode: `nodelay(H, 1, 10, 2, 1)`
- Increase window size: `wndsize(H, 256, 256)`
- Reduce update interval to 10ms
