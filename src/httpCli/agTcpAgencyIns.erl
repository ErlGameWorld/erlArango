-module(agTcpAgencyIns).
-include("agHttpCli.hrl").
-include("erlArango.hrl").

-compile(inline).
-compile({inline_size, 128}).

-export([
   %% 内部行为API
   init/1
   , handleMsg/3
   , terminate/3
]).

-spec init(term()) -> no_return().
init({PoolName, AgencyName, #agencyOpts{reconnect = Reconnect, backlogSize = BacklogSize, reconnectTimeMin = Min, reconnectTimeMax = Max}}) ->
   ReconnectState = agAgencyUtils:initReconnectState(Reconnect, Min, Max),
   self() ! ?miDoNetConnect,
   {ok, #srvState{poolName = PoolName, serverName = AgencyName, rn = binary:compile_pattern(<<"\r\n">>), rnrn = binary:compile_pattern(<<"\r\n\r\n">>), reconnectState = ReconnectState}, #cliState{backlogSize = BacklogSize}}.

-spec handleMsg(term(), srvState(), cliState()) -> {ok, term(), term()}.
handleMsg(#miRequest{method = Method, path = Path, headers = Headers, body = Body, requestId = RequestId, fromPid = FromPid, overTime = OverTime, isSystem = IsSystem} = MiRequest,
   #srvState{serverName = ServerName, host = Host, userPassWord = UserPassWord, dbName = DbName, socket = Socket} = SrvState,
   #cliState{backlogNum = BacklogNum, backlogSize = BacklogSize, requestsIn = RequestsIn, status = Status} = CliState) ->
   case Socket of
      undefined ->
         agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, no_socket}),
         {ok, SrvState, CliState};
      _ ->
         case BacklogNum >= BacklogSize of
            true ->
               ?WARN(ServerName, ":backlog full curNum:~p Total: ~p ~n", [BacklogNum, BacklogSize]),
               agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, backlog_full}),
               {ok, SrvState, CliState};
            _ ->
               case Status of
                  leisure -> %% 空闲模式
                     Request = agHttpProtocol:request(IsSystem, Body, Method, Host, DbName, Path, [UserPassWord | Headers]),
                     io:format("IMY*******************************~n~p ~n", [Request]),
                     case gen_tcp:send(Socket, Request) of
                        ok ->
                           TimerRef =
                              case OverTime of
                                 infinity ->
                                    undefined;
                                 _ ->
                                    erlang:start_timer(OverTime, self(), waiting_over, [{abs, true}])
                              end,
                           {ok, SrvState, CliState#cliState{isHeadMethod = Method == ?Head, status = waiting, backlogNum = BacklogNum + 1, curInfo = {FromPid, RequestId, TimerRef}}};
                        {error, Reason} ->
                           ?WARN(ServerName, ":send error: ~p ~p ~p ~n", [Reason, FromPid, RequestId]),
                           gen_tcp:close(Socket),
                           agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, {socket_send_error, Reason}}),
                           agAgencyUtils:dealClose(SrvState, CliState, {error, {socket_send_error, Reason}})
                     end;
                  _ ->
                     agAgencyUtils:addQueue(RequestsIn, MiRequest),
                     {ok, SrvState, CliState#cliState{requestsIn = RequestsIn + 1, backlogNum = BacklogNum + 1}}
               end
         end
   end;
handleMsg({tcp, Socket, Data},
   #srvState{serverName = ServerName, rn = Rn, rnrn = RnRn, socket = Socket} = SrvState,
   #cliState{isHeadMethod = IsHeadMethod, backlogNum = BacklogNum, curInfo = CurInfo, requestsOut = RequestsOut, recvState = RecvState} = CliState) ->
   try agHttpProtocol:response(RecvState, Rn, RnRn, Data, IsHeadMethod) of
      {done, #recvState{statusCode = StatusCode, contentLength = ContentLength, body = Body}} ->
         agAgencyUtils:agencyReply(CurInfo, #requestRet{statusCode = StatusCode, contentLength = ContentLength, body = Body}),
         case agAgencyUtils:getQueue(RequestsOut + 1) of
            undefined ->
               {ok, SrvState, CliState#cliState{backlogNum = BacklogNum - 1, status = leisure, curInfo = undefined, recvState = undefined}};
            MiRequest ->
               dealQueueRequest(MiRequest, SrvState, CliState#cliState{backlogNum = BacklogNum - 1, status = leisure, curInfo = undefined, recvState = undefined})
         end;
      {ok, NewRecvState} ->
         {ok, SrvState, CliState#cliState{recvState = NewRecvState}};
      {error, Reason} ->
         ?WARN(ServerName, "handle tcp data error: ~p ~p ~n", [Reason, CurInfo]),
         gen_tcp:close(Socket),
         agAgencyUtils:dealClose(SrvState, CliState, {error, {tcp_data_error, Reason}})
   catch
      E:R:S ->
         ?WARN(ServerName, "handle tcp data crash: ~p:~p~n~p~n ~p ~n ", [E, R, S, CurInfo]),
         gen_tcp:close(Socket),
         agAgencyUtils:dealClose(SrvState, CliState, {error, agency_handledata_error})
   end;
handleMsg({timeout, TimerRef, waiting_over},
   #srvState{socket = Socket} = SrvState,
   #cliState{backlogNum = BacklogNum, curInfo = {FromPid, RequestId, TimerRef}} = CliState) ->
   agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, timeout}),
   %% 之前的数据超时之后 要关闭tcp 然后重新建立连接 以免后面该tcp收到该次超时数据 影响后面请求的接收数据 导致数据错乱
   gen_tcp:close(Socket),
   handleMsg(?miDoNetConnect, SrvState#srvState{socket = undefined}, CliState#cliState{backlogNum = BacklogNum - 1});
handleMsg({tcp_closed, Socket},
   #srvState{socket = Socket, serverName = ServerName} = SrvState,
   CliState) ->
   ?WARN(ServerName, "connection closed~n", []),
   gen_tcp:close(Socket),
   agAgencyUtils:dealClose(SrvState, CliState, {error, tcp_closed});
handleMsg({tcp_error, Socket, Reason},
   #srvState{socket = Socket, serverName = ServerName} = SrvState,
   CliState) ->
   ?WARN(ServerName, "connection error: ~p~n", [Reason]),
   gen_tcp:close(Socket),
   agAgencyUtils:dealClose(SrvState, CliState, {error, {tcp_error, Reason}});
handleMsg(?miDoNetConnect,
   #srvState{poolName = PoolName, serverName = ServerName, reconnectState = ReconnectState} = SrvState,
   #cliState{requestsOut = RequestsOut} = CliState) ->
   case ?agBeamPool:get(PoolName) of
      #dbOpts{host = Host, port = Port, hostname = HostName, dbName = DbName, userPassword = UserPassword, socketOpts = SocketOpts} ->
         case dealConnect(ServerName, HostName, Port, SocketOpts) of
            {ok, Socket} ->
               NewReconnectState = agAgencyUtils:resetReconnectState(ReconnectState),
               %% 新建连接之后 需要重置之前的buff之类状态数据
               NewCliState = CliState#cliState{status = leisure, recvState = undefined, curInfo = undefined},
               case agAgencyUtils:getQueue(RequestsOut + 1) of
                  undefined ->
                     {ok, SrvState#srvState{userPassWord = UserPassword, dbName = DbName, host = Host, reconnectState = NewReconnectState, socket = Socket}, NewCliState};
                  MiRequest ->
                     dealQueueRequest(MiRequest, SrvState#srvState{socket = Socket, reconnectState = NewReconnectState}, NewCliState)
               end;
            {error, _Reason} ->
               agAgencyUtils:reconnectTimer(SrvState, CliState)
         end;
      _Ret ->
         ?WARN(ServerName, "deal connect not found agBeamPool:get(~p) ret ~p is error ~n", [PoolName, _Ret])
   end;
handleMsg(Msg, #srvState{serverName = ServerName} = SrvState, CliState) ->
   ?WARN(ServerName, "unknown msg: ~p~n", [Msg]),
   {ok, SrvState, CliState}.

-spec terminate(term(), srvState(), cliState()) -> ok.
terminate(_Reason,
   #srvState{socket = Socket, timerRef = TimerRef} = SrvState,
   #cliState{requestsOut = RequestsOut, status = Status} = CliState) ->
   io:format("IMY*******************terminate  ~p~n", [_Reason]),
   {ok, NewSrvState, NewCliState} = overAllWork(SrvState, CliState),
   gen_tcp:close(Socket),
   agAgencyUtils:cancelTimer(TimerRef),
   agAgencyUtils:dealClose(NewSrvState, NewCliState, {error, shutdown}),
   ok.

-spec overAllWork(srvState(), cliState()) -> ok.
overAllWork(#srvState{serverName = ServerName, rn = Rn, rnrn = RnRn, socket = Socket, timerRef = TimerRef} = SrvState,
   #cliState{isHeadMethod = IsHeadMethod, backlogNum = BacklogNum, curInfo = CurInfo, requestsOut = RequestsOut, recvState = RecvState, status = Status} = CliState) ->
   case Status of
      leisure ->
         case agAgencyUtils:getQueue(RequestsOut + 1) of
            undefined ->
               ok;
            MiRequest ->
               overDealQueueRequest(MiRequest, SrvState, CliState)
         end;
      _ ->
         overReceiveTcpData(SrvState, CliState)
   end,
   ok.

-spec overDealQueueRequest(miRequest(), srvState(), cliState()) -> {ok, srvState(), cliState()}.
overDealQueueRequest(#miRequest{method = Method, path = Path, headers = Headers, body = Body, requestId = RequestId, fromPid = FromPid, overTime = OverTime, isSystem = IsSystem},
   #srvState{serverName = ServerName, host = Host, userPassWord = UserPassWord, dbName = DbName, socket = Socket} = SrvState,
   #cliState{requestsOut = RequestsOut, backlogNum = BacklogNum} = CliState) ->
   agAgencyUtils:delQueue(RequestsOut + 1),
   case erlang:system_time(millisecond) > OverTime of
      true ->
         %% 超时了
         agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, timeout}),
         case agAgencyUtils:getQueue(RequestsOut + 2) of
            undefined ->
               ok;
            MiRequest ->
               overDealQueueRequest(MiRequest, SrvState, CliState#cliState{requestsOut = RequestsOut + 1, backlogNum = BacklogNum - 1})
         end;
      _ ->
         Request = agHttpProtocol:request(IsSystem, Body, Method, Host, DbName, Path, [UserPassWord | Headers]),
         case gen_tcp:send(Socket, Request) of
            ok ->
               TimerRef =
                  case OverTime of
                     infinity ->
                        undefined;
                     _ ->
                        erlang:start_timer(OverTime, self(), waiting_over, [{abs, true}])
                  end,
               overReceiveTcpData(SrvState, CliState#cliState{isHeadMethod = Method == ?Head, status = waiting, requestsOut = RequestsOut + 1, curInfo = {FromPid, RequestId, TimerRef}});
            {error, Reason} ->
               ?WARN(ServerName, ":send error: ~p~n", [Reason]),
               gen_tcp:close(Socket),
               agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, socket_send_error}),
               agAgencyUtils:dealClose(SrvState, CliState, {error, socket_send_error})
         end
   end.


-spec overReceiveTcpData(srvState(), cliState()) -> term().
overReceiveTcpData(#srvState{poolName = PoolName, serverName = ServerName, rn = Rn, rnrn = RnRn, socket = Socket} = SrvState,
   #cliState{isHeadMethod = IsHeadMethod, backlogNum = BacklogNum, curInfo = CurInfo, requestsOut = RequestsOut, recvState = RecvState} = CliState) ->
   receive
      {tcp, Socket, Data} ->
         try agHttpProtocol:response(RecvState, Rn, RnRn, Data, IsHeadMethod) of
            {done, #recvState{statusCode = StatusCode, contentLength = ContentLength, headers = Headers, body = Body}} ->
               agAgencyUtils:agencyReply(CurInfo, #requestRet{statusCode = StatusCode, contentLength = ContentLength, headers = Headers, body = Body}),
               case agAgencyUtils:getQueue(RequestsOut + 1) of
                  undefined ->
                     %% todo bug fix
                     ok;
                  MiRequest ->
                     overDealQueueRequest(MiRequest, SrvState, CliState#cliState{backlogNum = BacklogNum - 1, status = leisure, curInfo = undefined, recvState = undefined})
               end;
            {ok, NewRecvState} ->
               overReceiveTcpData(SrvState, CliState#cliState{recvState = NewRecvState});
            {error, Reason} ->
               ?WARN(overReceiveTcpData, "handle tcp data error: ~p ~n", [Reason]),
               gen_tcp:close(Socket),
               agAgencyUtils:dealClose(SrvState, CliState, {error, {tcp_data_error, Reason}})
         catch
            E:R:S ->
               ?WARN(overReceiveTcpData, "handle tcp data crash: ~p:~p~n~p ~n ", [E, R, S]),
               gen_tcp:close(Socket),
               agAgencyUtils:dealClose(SrvState, CliState, {error, {tcp_error, handledata_error}}),
               ok
         end;
      {timeout, _TimerRef, waiting_over} ->
         gen_tcp:close(Socket),
         agAgencyUtils:agencyReply(CurInfo, {error, timeout}),
         case agAgencyUtils:getQueue(RequestsOut + 1) of
            undefined ->
               ok;
            MiRequest ->
               case ?agBeamPool:get(PoolName) of
                  #dbOpts{port = Port, hostname = HostName, socketOpts = SocketOpts} ->
                     case dealConnect(ServerName, HostName, Port, SocketOpts) of
                        {ok, NewSocket} ->
                           %% 新建连接之后 需要重置之前的buff之类状态数据
                           NewCliState = CliState#cliState{status = leisure, recvState = undefined, curInfo = undefined},
                           overDealQueueRequest(MiRequest, SrvState#srvState{socket = NewSocket}, NewCliState);
                        {error, _Reason} ->
                           agAgencyUtils:dealClose(SrvState, CliState, {error, {new_tcp_connect_error_over, _Reason}}),
                           ok
                     end;
                  _Ret ->
                     agAgencyUtils:dealClose(SrvState, CliState, {error, {not_found_poolName, PoolName}}),
                     ok
               end
         end;
      {tcp_closed, Socket} ->
         gen_tcp:close(Socket),
         agAgencyUtils:dealClose(SrvState, CliState, {error, tcp_closed}),
         ok;
      {tcp_error, Socket, Reason} ->
         gen_tcp:close(Socket),
         agAgencyUtils:dealClose(SrvState, CliState, {error, {tcp_error, Reason}}),
         ok
   end.

-spec dealConnect(atom(), hostName(), port(), socketOpts()) -> {ok, socket()} | {error, term()}.
dealConnect(ServerName, HostName, Port, SocketOptions) ->
   case inet:getaddrs(HostName, inet) of
      {ok, IPList} ->
         Ip = agMiscUtils:randomElement(IPList),
         case gen_tcp:connect(Ip, Port, SocketOptions, ?DEFAULT_CONNECT_TIMEOUT) of
            {ok, Socket} ->
               {ok, Socket};
            {error, Reason} ->
               ?WARN(ServerName, "connect error: ~p~n", [Reason]),
               {error, Reason}
         end;
      {error, Reason} ->
         ?WARN(ServerName, "getaddrs error: ~p~n", [Reason]),
         {error, Reason}
   end.

-spec dealQueueRequest(miRequest(), srvState(), cliState()) -> {ok, srvState(), cliState()}.
dealQueueRequest(#miRequest{method = Method, path = Path, headers = Headers, body = Body, requestId = RequestId, fromPid = FromPid, overTime = OverTime, isSystem = IsSystem},
   #srvState{serverName = ServerName, host = Host, userPassWord = UserPassWord, dbName = DbName, socket = Socket} = SrvState,
   #cliState{requestsOut = RequestsOut, backlogNum = BacklogNum} = CliState) ->
   agAgencyUtils:delQueue(RequestsOut + 1),
   case erlang:system_time(millisecond) > OverTime of
      true ->
         %% 超时了
         agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, timeout}),
         case agAgencyUtils:getQueue(RequestsOut + 2) of
            undefined ->
               {ok, SrvState, CliState#cliState{requestsOut = RequestsOut + 1}};
            MiRequest ->
               dealQueueRequest(MiRequest, SrvState, CliState#cliState{requestsOut = RequestsOut + 1, backlogNum = BacklogNum - 1})
         end;
      _ ->
         Request = agHttpProtocol:request(IsSystem, Body, Method, Host, DbName, Path, [UserPassWord | Headers]),
         case gen_tcp:send(Socket, Request) of
            ok ->
               TimerRef =
                  case OverTime of
                     infinity ->
                        undefined;
                     _ ->
                        erlang:start_timer(OverTime, self(), waiting_over, [{abs, true}])
                  end,
               {ok, SrvState, CliState#cliState{isHeadMethod = Method == ?Head, status = waiting, requestsOut = RequestsOut + 1, curInfo = {FromPid, RequestId, TimerRef}}};
            {error, Reason} ->
               ?WARN(ServerName, ":send error: ~p~n", [Reason]),
               gen_tcp:close(Socket),
               agAgencyUtils:agencyReply(FromPid, RequestId, undefined, {error, socket_send_error}),
               agAgencyUtils:dealClose(SrvState, CliState, {error, socket_send_error})
         end
   end.

