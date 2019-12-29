-module(test).


-compile([export_all, nowarn_export_all]).


tt(C, N) ->
   application:start(erlArango),
   agHttpCli:startPool(tt, [{poolSize, 100}], []),
   Request = {<<"GET">>, <<"/_api/database/current">>, [], []},
   io:format("IMY**********************  start time ~p~n",[erlang:system_time(millisecond)]),
   [spawn(test, test, [N, Request]) || _Idx <- lists:seq(1, C)].
   %%test(N, Request).

%% /_api/database

test(0, Request) ->
   R1 = {<<"GET">>, <<"/_api/database">>, [], []},
   agHttpCli:callAgency(tt, R1, 5000),
   io:format("IMY**********************  test over ~p~n",[erlang:system_time(millisecond)]);
test(N, Request) ->
   erlang:put(cnt, N),
   agHttpCli:callAgency(tt, Request, 5000),
   test(N - 1, Request).

%% tt(C, N) ->
%%    application:start(erlArango),
%%    agHttpCli:startPool(tt, [{poolSize, 1}, {baseUrl, <<"http://localhost:8181">>}], []),
%%    Request = {<<"GET">>, <<"/_api/database/current">>, [], []},
%%    io:format("IMY**********************  start time ~p~n",[erlang:system_time(millisecond)]),
%%    [spawn(test, test, [N, Request]) || _Idx <- lists:seq(1, C)].
%% %%test(N, Request).
%%
%% %% /_api/database
%%
%% test(0, Request) ->
%%    R1 = {<<"POST">>, <<"/echo_body">>, [], []},
%%    agHttpCli:callAgency(tt, {<<"GET">>, <<"/ibrowse_stream_once_chunk_pipeline_test">>, [], []}, infinity),
%%    agHttpCli:callAgency(tt, {<<"POST">>, <<"/echo_body">>, [], []}, infinity),
%%    io:format("IMY**********************  test over ~p~n",[erlang:system_time(millisecond)]);
%% test(N, Request) ->
%%    erlang:put(cnt, N),
%%    agHttpCli:callAgency(tt, Request, 5000),
%%    test(N - 1, Request).