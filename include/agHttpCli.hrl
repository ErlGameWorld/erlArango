%% beam cache 模块名
-define(agBeamPool, agBeamPool).
-define(agBeamAgency, agBeamAgency).

%% 默认值定义
-define(DEFAULT_BASE_URL, <<"http://120.77.213.39:8529">>).
-define(USER_PASSWORD, <<"root:156736">>).
-define(DEFAULT_BACKLOG_SIZE, 1024).
-define(DEFAULT_INIT_OPTS, undefined).
-define(DEFAULT_CONNECT_TIMEOUT, 500).
-define(DEFAULT_POOL_SIZE, 16).
-define(DEFAULT_POOL_STRATEGY, random).
-define(DEFAULT_POOL_OPTIONS, []).
-define(DEFAULT_IS_RECONNECT, true).
-define(DEFAULT_RECONNECT_MAX, 120000).
-define(DEFAULT_RECONNECT_MIN, 500).
-define(DEFAULT_SOCKET_OPTS, [binary, {packet, line}, {packet, raw}, {send_timeout, 50}, {send_timeout_close, true}]).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_BODY, undefined).
-define(DEFAULT_HEADERS, []).
-define(DEFAULT_PID, self()).
-define(DEFAULT_PROTOCOL, tcp).
-define(DEFAULT_PORTO(Protocol), 8529).
%%-define(DEFAULT_PORTO(Protocol), case Protocol of tcp -> 80; _ -> 443 end).

-define(GET_FROM_LIST(Key, List), agMiscUtils:getListValue(Key, List, undefined)).
-define(GET_FROM_LIST(Key, List, Default), agMiscUtils:getListValue(Key, List, Default)).

-define(WARN(Tag, Format, Data), agMiscUtils:warnMsg(Tag, Format, Data)).

-define(miDoNetConnect, miDoNetConnect).

-record(miAgHttpCliRet, {
   requestId :: requestId(),
   reply :: term()
}).

-record(request, {
   requestId :: requestId(),
   pid :: pid() | undefined,
   timeout :: timeout(),
   timestamp :: erlang:timestamp()
}).

-record(requestRet, {
   state :: body | done,
   body :: undefined | binary(),
   content_length :: undefined | non_neg_integer() | chunked,
   headers :: undefined | [binary()],
   reason :: undefined | binary(),
   status_code :: undefined | 100..505
}).

-record(httpParam, {
   headers = [] :: [binary()],
   body = undefined :: undefined | binary(),
   pid = self() :: pid(),
   timeout = 1000 :: non_neg_integer()
}).

-record(reconnectState, {
   min :: non_neg_integer(),
   max :: non_neg_integer() | infinity,
   current :: non_neg_integer() | undefined
}).

-record(cliState, {
   requestsIn = 0 :: non_neg_integer(),
   requestsOut = 0 :: non_neg_integer(),
   binPatterns :: tuple(),
   buffer = <<>> :: binary(),
   response :: requestRet() | undefined,
   backlogNum = 0 :: integer(),
   backlogSize :: integer()
}).

-record(poolOpts, {
   host :: host(),
   port :: 0..65535,
   hostname :: string(),
   protocol :: protocol(),
   userPassword :: binary(),
   poolSize ::binary()
}).

-type miAgHttpCliRet() :: #miAgHttpCliRet{}.
-type request() :: #request{}.
-type requestRet() :: #requestRet{}.
-type httpParam() :: #httpParam{}.
-type cliState() :: #cliState{}.
-type reconnectState() :: #reconnectState{}.

-type poolName() :: atom().
-type serverName() :: atom().
-type protocol() :: ssl | tcp.
-type method() :: binary().
-type headers() :: [{iodata(), iodata()}].
-type body() :: iodata() | undefined.
-type path() :: binary().
-type host() :: binary().
-type poolSize() :: pos_integer().
-type backlogSize() :: pos_integer() | infinity.
-type requestId() :: {serverName(), reference()}.
-type externalRequestId() :: term().
-type response() :: {externalRequestId(), term()}.
-type socket() :: inet:socket() | ssl:sslsocket().
-type error() :: {error, term()}.

-type poolCfg() ::
   {baseUrl, binary()} |
   {user, binary()} |
   {password, binary()} |
   {poolSize, poolSize()}.

-type agencyOpt() ::
   {reconnect, boolean()} |
   {backlogSize, backlogSize()} |
   {reconnectTimeMin, pos_integer()} |
   {reconnectTimeMax, pos_integer()} |
   {socketOpts, [gen_tcp:connect_option(), ...]}.

-type poolCfgs() :: [poolCfg()].
-type poolOpts() :: #poolOpts{}.
-type agencyOpts() :: [agencyOpt()].

-record(dbUrl, {
   host :: host(),
   path :: path(),
   port :: 0..65535,
   hostname :: string(),
   protocol :: protocol(),
   poolName :: atom()               %% 请求该URL用到的poolName
}).

-type dbUrl() :: #dbUrl{}.

