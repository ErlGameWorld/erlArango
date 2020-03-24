%% agency 管理进程的名称
-define(agAgencyPoolMgr, agAgencyPoolMgr).

%% beam cache 模块名
-define(agBeamPool, agBeamPool).
-define(agBeamAgency, agBeamAgency).

%% 默认值定义
-define(DEFAULT_BASE_URL, <<"http://120.77.213.39:8529">>).
-define(DEFAULT_DBNAME, <<"_db/_system">>).
-define(USER_PASSWORD, <<"root:156736">>).
-define(DEFAULT_BACKLOG_SIZE, 1024).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_POOL_SIZE, 16).
-define(DEFAULT_IS_RECONNECT, true).
-define(DEFAULT_RECONNECT_MIN, 500).
-define(DEFAULT_RECONNECT_MAX, 120000).
-define(DEFAULT_TIMEOUT, infinity).
-define(DEFAULT_PID, self()).
-define(DEFAULT_SOCKET_OPTS, [binary, {active, true}, {delay_send, true}, {nodelay, true}, {keepalive, true}, {recbuf, 1048576}, {send_timeout, 5000}, {send_timeout_close, true}]).

-define(GET_FROM_LIST(Key, List), agMiscUtils:getListValue(Key, List, undefined)).
-define(GET_FROM_LIST(Key, List, Default), agMiscUtils:getListValue(Key, List, Default)).
-define(WARN(Tag, Format, Data), agMiscUtils:warnMsg(Tag, Format, Data)).

-define(miDoNetConnect, miDoNetConnect).

-record(miRequest, {
   method :: method()
   , path :: path()
   , headers :: headers()
   , body :: body()
   , requestId :: tuple()
   , fromPid :: pid()
   , overTime = infinity :: timeout()
   , isSystem = false :: boolean()
}).

-record(miAgHttpCliRet, {
   requestId :: requestId(),
   reply :: term()
}).

-record(requestRet, {
   statusCode :: undefined | 100..505,
   contentLength :: undefined | non_neg_integer() | chunked,
   headers :: undefined | [binary()],
   body :: undefined | binary()
}).

-record(recvState, {
   stage = header :: header | body | done,                    %% 一个请求收到tcp可能会有多个包 最多分三个阶接收
   contentLength :: undefined | non_neg_integer() | chunked,
   statusCode :: undefined | 100..505,
   headers :: undefined | [binary()],
   buffer = <<>> :: binary(),
   body = <<>> :: binary()
}).

-record(reconnectState, {
   min :: non_neg_integer(),
   max :: non_neg_integer() | infinity,
   current :: non_neg_integer() | undefined
}).

-record(srvState, {
   poolName :: poolName(),
   serverName :: serverName(),
   userPassWord :: binary(),
   host :: binary(),
   dbName :: binary(),
   rn :: binary:cp(),
   rnrn :: binary:cp(),
   reconnectState :: undefined | reconnectState(),
   socket :: undefined | ssl:sslsocket(),
   timerRef :: undefined | reference()
}).

-record(cliState, {
   isHeadMethod = false :: boolean(),           %% 是否是<<"HEAD">>请求方法
   %method = undefined :: undefined | method(),
   requestsIn = 1 :: non_neg_integer(),
   requestsOut = 0 :: non_neg_integer(),
   backlogNum = 0 :: integer(),
   backlogSize = 0 :: integer(),
   status = leisure :: waiting | leisure,
   curInfo = undefined :: tuple(),
   recvState = undefined :: recvState() | undefined
}).

-record(dbOpts, {
   host :: host(),
   port :: 0..65535,
   hostname :: hostName(),
   dbName :: binary(),
   protocol :: protocol(),
   poolSize :: binary(),
   userPassword :: binary(),
   socketOpts :: socketOpts()
}).

-record(agencyOpts, {
   reconnect :: boolean(),
   backlogSize :: backlogSize(),
   reconnectTimeMin :: pos_integer(),
   reconnectTimeMax :: pos_integer()
}).

-type miRequest() :: #miRequest{}.
-type miAgHttpCliRet() :: #miAgHttpCliRet{}.
-type requestRet() :: #requestRet{}.
-type recvState() :: #recvState{}.
-type srvState() :: #srvState{}.
-type cliState() :: #cliState{}.
-type reconnectState() :: #reconnectState{}.

-type poolName() :: atom().
-type poolNameOrSocket() :: atom() | socket().
-type serverName() :: atom().
-type protocol() :: ssl | tcp.
-type method() :: binary().
-type headers() :: [{iodata(), iodata()}].
-type body() :: iodata() | undefined.
-type path() :: binary().
-type host() :: binary().
-type hostName() :: string().
-type poolSize() :: pos_integer().
-type backlogSize() :: pos_integer() | infinity.
-type requestId() :: {serverName(), reference()}.
-type socket() :: inet:socket() | ssl:sslsocket().
-type socketOpts() :: [gen_tcp:connect_option(), ...].
-type error() :: {error, term()}.

-type dbCfg() ::
   {baseUrl, binary()} |
   {dbName, binary()} |
   {userPassword, binary()} |
   {poolSize, poolSize()} |
   {socketOpts, [gen_tcp:connect_option(), ...]}.

-type agencyCfg() ::
   {reconnect, boolean()} |
   {backlogSize, backlogSize()} |
   {reconnectTimeMin, pos_integer()} |
   {reconnectTimeMax, pos_integer()}.

-type dbCfgs() :: [dbCfg()].
-type dbOpts() :: #dbOpts{}.
-type agencyCfgs() :: [agencyCfg()].
-type agencyOpts() :: #agencyOpts{}.

%% http header 头
%% -type header() ::
%%    'Cache-Control' |
%%    'Connection' |
%%    'Date' |
%%    'Pragma'|
%%    'Transfer-Encoding' |
%%    'Upgrade' |
%%    'Via' |
%%    'Accept' |
%%    'Accept-Charset'|
%%    'Accept-Encoding' |
%%    'Accept-Language' |
%%    'Authorization' |
%%    'From' |
%%    'Host' |
%%    'If-Modified-Since' |
%%    'If-Match' |
%%    'If-None-Match' |
%%    'If-Range'|
%%    'If-Unmodified-Since' |
%%    'Max-Forwards' |
%%    'Proxy-Authorization' |
%%    'Range'|
%%    'Referer' |
%%    'User-Agent' |
%%    'Age' |
%%    'Location' |
%%    'Proxy-Authenticate'|
%%    'Public' |
%%    'Retry-After' |
%%    'Server' |
%%    'Vary' |
%%    'Warning'|
%%    'Www-Authenticate' |
%%    'Allow' |
%%    'Content-Base' |
%%    'Content-Encoding'|
%%    'Content-Language' |
%%    'Content-Length' |
%%    'Content-Location'|
%%    'Content-Md5' |
%%    'Content-Range' |
%%    'Content-Type' |
%%    'Etag'|
%%    'Expires' |
%%    'Last-Modified' |
%%    'Accept-Ranges' |
%%    'Set-Cookie'|
%%    'Set-Cookie2' |
%%    'X-Forwarded-For' |
%%    'Cookie' |
%%    'Keep-Alive' |
%%    'Proxy-Connection' |
%%    binary() |
%%    string().

