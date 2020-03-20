-module(agHttpCli).
-include("agHttpCli.hrl").

-compile(inline).
-compile({inline_size, 128}).

-export([
   %% 请求通用API
   callAgency/5
   , callAgency/6
   , callAgency/7
   , castAgency/5
   , castAgency/6
   , castAgency/7
   , castAgency/8
   , receiveResponse/1

   %% 连接池API
   , startPool/2
   , startPool/3
   , stopPool/1

   %% 单进程操作DbAPI
   , connectDb/1
   , disConnectDb/1
   , getCurDbInfo/1
   , setCurDbName/2

]).

-spec callAgency(poolNameOrSocket(), method(), path(), headers(), body()) -> term() | {error, term()}.
callAgency(PoolNameOrSocket, Method, Path, Headers, Body) ->
   callAgency(PoolNameOrSocket, Method, Path, Headers, Body, false, ?DEFAULT_TIMEOUT).

-spec callAgency(poolNameOrSocket(), method(), path(), headers(), body(), boolean()) -> term() | {error, atom()}.
callAgency(PoolNameOrSocket, Method, Path, Headers, Body, IsSystem) ->
   callAgency(PoolNameOrSocket, Method, Path, Headers, Body, IsSystem, ?DEFAULT_TIMEOUT).

-spec callAgency(poolNameOrSocket(), method(), path(), headers(), body(), boolean(), timeout()) -> term() | {error, atom()}.
callAgency(PoolNameOrSocket, Method, Path, Headers, Body, IsSystem, Timeout) ->
   case castAgency(PoolNameOrSocket, Method, Path, Headers, Body, self(), IsSystem, Timeout) of
      {ok, RequestId} ->
         receiveResponse(RequestId);
      {error, _Reason} = Err ->
         Err;
      Ret ->
         Ret
   end.

-spec castAgency(poolNameOrSocket(), method(), path(), headers(), body()) -> {ok, requestId()} | {error, atom()}.
castAgency(PoolNameOrSocket, Method, Path, Headers, Body) ->
   castAgency(PoolNameOrSocket, Method, Path, Headers, Body, self(), false, ?DEFAULT_TIMEOUT).

-spec castAgency(poolNameOrSocket(), method(), path(), headers(), body(), boolean()) -> {ok, requestId()} | {error, atom()}.
castAgency(PoolNameOrSocket, Method, Path, Headers, Body, IsSystem) ->
   castAgency(PoolNameOrSocket, Method, Path, Headers, Body, self(), IsSystem, ?DEFAULT_TIMEOUT).

-spec castAgency(poolNameOrSocket(), method(), path(), headers(), body(), boolean(), timeout()) -> {ok, requestId()} | {error, atom()}.
castAgency(PoolNameOrSocket, Method, Path, Headers, Body, IsSystem, Timeout) ->
   castAgency(PoolNameOrSocket, Method, Path, Headers, Body, self(), IsSystem, Timeout).

-spec castAgency(poolNameOrSocket(), method(), path(), headers(), body(), pid(), boolean(), timeout()) -> {ok, requestId()} | {error, atom()}.
castAgency(PoolNameOrSocket, Method, Path, Headers, Body, Pid, IsSystem, Timeout) ->
   OverTime =
      case Timeout of
         infinity -> infinity;
         _ ->
            erlang:system_time(millisecond) + Timeout
      end,
   case erlang:is_atom(PoolNameOrSocket) of
      true ->
         case agAgencyPoolMgrIns:getOneAgency(PoolNameOrSocket) of
            {error, pool_not_found} = Err ->
               Err;
            undefined ->
               {error, undefined_server};
            AgencyName ->
               RequestId = {AgencyName, make_ref()},
               catch AgencyName ! #miRequest{method = Method, path = Path, headers = Headers, body = Body, requestId = RequestId, fromPid = Pid, overTime = OverTime, isSystem = IsSystem},
               {ok, RequestId}
         end;
      _ ->
         case getCurDbInfo(PoolNameOrSocket) of
            {DbName, UserPassWord, Host, Protocol} ->
               Request = agHttpProtocol:request(IsSystem, Body, Method, Host, DbName, Path, [{<<"Authorization">>, UserPassWord} | Headers]),
               io:format("IMY*******************************~n~p ~n",[Request]),
               case Protocol of
                  tcp ->
                     case gen_tcp:send(PoolNameOrSocket, Request) of
                        ok ->
                           TimerRef =
                              case OverTime of
                                 infinity ->
                                    undefined;
                                 _ ->
                                    erlang:start_timer(OverTime, self(), waiting_over, [{abs, true}])
                              end,
                           receiveTcpData(undefined, PoolNameOrSocket, TimerRef, binary:compile_pattern(<<"\r\n">>), binary:compile_pattern(<<"\r\n\r\n">>));
                        {error, Reason} = Err ->
                           ?WARN(castAgency, ":gen_tcp send error: ~p ~n", [Reason]),
                           disConnectDb(PoolNameOrSocket),
                           Err
                     end;
                  ssl ->
                     case ssl:send(PoolNameOrSocket, Request) of
                        ok ->
                           TimerRef =
                              case OverTime of
                                 infinity ->
                                    undefined;
                                 _ ->
                                    erlang:start_timer(OverTime, self(), waiting_over, [{abs, true}])
                              end,
                           receiveSslData(undefined, PoolNameOrSocket, TimerRef, binary:compile_pattern(<<"\r\n">>), binary:compile_pattern(<<"\r\n\r\n">>));
                        {error, Reason} = Err ->
                           ?WARN(castAgency, ":ssl send error: ~p ~n", [Reason]),
                           disConnectDb(PoolNameOrSocket),
                           Err
                     end
               end;
            _ ->
               {error, dbinfo_not_found}
         end
   end.

-spec receiveResponse(requestId()) -> term() | {error, term()}.
receiveResponse(RequestId) ->
   receive
      #miAgHttpCliRet{requestId = RequestId, reply = Reply} ->
         Reply
   end.

-spec receiveTcpData(recvState() | undefined, socket(), reference() | undefined, binary:cp(), binary:cp()) -> requestRet() | {error, term()}.
receiveTcpData(RecvState, Socket, TimerRef, Rn, RnRn) ->
   receive
      {tcp, Socket, Data} ->
         io:format("IMY*******************************  ~p ~n ",[Data]),
         try agHttpProtocol:response(RecvState, Rn, RnRn, Data) of
            {done, #recvState{statusCode = StatusCode, contentLength = ContentLength, headers = Headers, body = Body}} ->
               #requestRet{statusCode = StatusCode, contentLength = ContentLength, headers= Headers, body = Body};
            {ok, NewRecvState} ->
               receiveTcpData(NewRecvState, Socket, TimerRef, Rn, RnRn);
            {error, Reason} ->
               ?WARN(receiveTcpData, "handle tcp data error: ~p ~n", [Reason]),
               disConnectDb(Socket),
               {error, {tcp_data_error, Reason}}
         catch
            E:R:S ->
               ?WARN(receiveTcpData, "handle tcp data crash: ~p:~p~n~p ~n ", [E, R, S]),
               disConnectDb(Socket),
               {error, handledata_error}
         end;
      {timeout, TimerRef, waiting_over} ->
         {error, timeout};
      {tcp_closed, Socket} ->
         disConnectDb(Socket),
         {error, tcp_closed};
      {tcp_error, Socket, Reason} ->
         disConnectDb(Socket),
         {error, {tcp_error, Reason}}
   end.

-spec receiveSslData(recvState() | undefined, socket(), reference() | undefined, binary:cp(), binary:cp()) -> requestRet() | {error, term()}.
receiveSslData(RecvState, Socket, TimerRef, Rn, RnRn) ->
   receive
      {ssl, Socket, Data} ->
         try agHttpProtocol:response(RecvState, Rn, RnRn, Data) of
            {done, #recvState{statusCode = StatusCode, contentLength = ContentLength, body = Body}} ->
               #requestRet{statusCode = StatusCode, contentLength = ContentLength, body = Body};
            {ok, NewRecvState} ->
               receiveTcpData(NewRecvState, Socket, TimerRef, Rn, RnRn);
            {error, Reason} ->
               ?WARN(receiveSslData, "handle tcp data error: ~p ~n", [Reason]),
               disConnectDb(Socket),
               {error, {ssl_data_error, Reason}}
         catch
            E:R:S ->
               ?WARN(receiveSslData, "handle tcp data crash: ~p:~p~n~p ~n ", [E, R, S]),
               disConnectDb(Socket),
               {error, handledata_error}
         end;
      {timeout, TimerRef, waiting_over} ->
         {error, timeout};
      {ssl_closed, Socket} ->
         disConnectDb(Socket),
         {error, ssl_closed};
      {ssl_error, Socket, Reason} ->
         disConnectDb(Socket),
         {error, {ssl_error, Reason}}
   end.

-spec startPool(poolName(), dbCfgs()) -> ok | {error, pool_name_used}.
startPool(PoolName, DbCfgs) ->
   agAgencyPoolMgrIns:startPool(PoolName, DbCfgs, []).

-spec startPool(poolName(), dbCfgs(), agencyCfgs()) -> ok | {error, pool_name_used}.
startPool(PoolName, DbCfgs, AgencyCfgs) ->
   agAgencyPoolMgrIns:startPool(PoolName, DbCfgs, AgencyCfgs).

-spec stopPool(poolName()) -> ok | {error, pool_not_started}.
stopPool(PoolName) ->
   agAgencyPoolMgrIns:stopPool(PoolName).

-spec connectDb(dbCfgs()) -> {ok, socket()} | error.
connectDb(DbCfgs) ->
   #dbOpts{
      host = Host,
      port = Port,
      hostname = HostName,
      dbName = DbName,
      protocol = Protocol,
      userPassword = UserPassword,
      socketOpts = SocketOpts
   } = agMiscUtils:dbOpts(DbCfgs),
   case inet:getaddrs(HostName, inet) of
      {ok, IPList} ->
         Ip = agMiscUtils:randomElement(IPList),
         case Protocol of
            tcp ->
               case gen_tcp:connect(Ip, Port, SocketOpts, ?DEFAULT_CONNECT_TIMEOUT) of
                  {ok, Socket} ->
                     setCurDbInfo(Socket, DbName, UserPassword, Host, Protocol),
                     {ok, Socket};
                  {error, Reason} = Err ->
                     ?WARN(connectDb, "connect error: ~p~n", [Reason]),
                     Err
               end;
            ssl ->
               case ssl:connect(Ip, Port, SocketOpts, ?DEFAULT_CONNECT_TIMEOUT) of
                  {ok, Socket} ->
                     setCurDbInfo(Socket, DbName, UserPassword, Host, Protocol),
                     {ok, Socket};
                  {error, Reason} = Err ->
                     ?WARN(connectDb, "connect error: ~p~n", [Reason]),
                     Err
               end
         end;
      {error, Reason} = Err ->
         ?WARN(connectDb, "getaddrs error: ~p~n", [Reason]),
         Err
   end.

disConnectDb(Socket) ->
   case erlang:erase({'$agDbInfo', Socket}) of
      undefined ->
         ignore;
      {_DbName, _UserPassword, _Host, Protocol} ->
         case Protocol of
            tcp ->
               gen_tcp:close(Socket);
            ssl ->
               ssl:close(Socket)
         end
   end.

setCurDbInfo(Socket, DbName, UserPassword, Host, Protocol) ->
   erlang:put({'$agDbInfo', Socket}, {DbName, UserPassword, Host, Protocol}).

getCurDbInfo(Socket) ->
   erlang:get({'$agDbInfo', Socket}).

setCurDbName(Socket, NewDbName) ->
   case erlang:get({'$agDbInfo', Socket}) of
      undefined ->
         ignore;
      {_DbName, UserPassword, Host, Protocol} ->
         erlang:put({'$agDbInfo', Socket}, {NewDbName, UserPassword, Host, Protocol})
   end,
   ok.
