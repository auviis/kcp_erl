%%%-------------------------------------------------------------------
%%% @doc
%%% Basic KCP Tests
%%% @end
%%%-------------------------------------------------------------------
-module(kcp_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Test Setup
%%%===================================================================

kcp_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_create_release/0,
      fun test_send_recv/0,
      fun test_update_check/0,
      fun test_nodelay/0,
      fun test_wndsize/0,
      fun test_setmtu/0,
      fun test_peeksize/0,
      fun test_waitsnd/0
     ]}.

setup() ->
    application:ensure_all_started(kcp),
    ok.

cleanup(_) ->
    application:stop(kcp),
    ok.

%%%===================================================================
%%% Tests
%%%===================================================================

test_create_release() ->
    %% Test creating and releasing a KCP instance
    Conv = 12345,
    {ok, Handle} = kcp:create(Conv),
    ?assert(is_integer(Handle)),
    ?assertEqual(ok, kcp:release(Handle)).

test_send_recv() ->
    %% Test send (recv will fail without input)
    {ok, Handle} = kcp:create(123),
    Data = <<"test data">>,
    ?assertEqual(ok, kcp:send(Handle, Data)),
    
    %% Should have no data to receive yet
    ?assertEqual({error, no_data}, kcp:recv(Handle)),
    
    kcp:release(Handle).

test_update_check() ->
    %% Test update and check
    {ok, Handle} = kcp:create(123),
    Current = erlang:system_time(millisecond) band 16#FFFFFFFF,
    
    ?assertEqual(ok, kcp:update(Handle, Current)),
    
    {ok, NextTime} = kcp:check(Handle, Current),
    ?assert(is_integer(NextTime)),
    
    kcp:release(Handle).

test_nodelay() ->
    %% Test nodelay configuration
    {ok, Handle} = kcp:create(123),
    
    %% Normal mode
    ?assertEqual(ok, kcp:nodelay(Handle, 0, 40, 0, 0)),
    
    %% Fast mode
    ?assertEqual(ok, kcp:nodelay(Handle, 1, 10, 2, 1)),
    
    kcp:release(Handle).

test_wndsize() ->
    %% Test window size configuration
    {ok, Handle} = kcp:create(123),
    
    ?assertEqual(ok, kcp:wndsize(Handle, 128, 128)),
    
    kcp:release(Handle).

test_setmtu() ->
    %% Test MTU configuration
    {ok, Handle} = kcp:create(123),
    
    ?assertEqual(ok, kcp:setmtu(Handle, 1400)),
    
    kcp:release(Handle).

test_peeksize() ->
    %% Test peek size (should be -1 with no data)
    {ok, Handle} = kcp:create(123),
    
    {ok, Size} = kcp:peeksize(Handle),
    ?assertEqual(-1, Size),
    
    kcp:release(Handle).

test_waitsnd() ->
    %% Test wait send count
    {ok, Handle} = kcp:create(123),
    
    {ok, Count} = kcp:waitsnd(Handle),
    ?assert(is_integer(Count)),
    
    kcp:release(Handle).
