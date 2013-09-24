%%% @doc
%%%
%%%   Export folsom metrics to graphite (UDP)
%%%
%%%   Atom, Binary, integer, tuple, list (not string!) name elements supported.
%%%
-module(folsograph).
-author('alexey.aniskin@gmail.com').

-behaviour(gen_server).

%% API
-export([start_link/0]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {interval, socket, host, port}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server
%%%===================================================================
init([]) ->
    {ok, Host} = application:get_env(graphite_host),
    {ok, Port} = application:get_env(graphite_port),
    {ok, Interval} = application:get_env(graphite_interval),
    erlang:send_after(Interval, self(), send),
    {ok, Socket} = gen_udp:open(0),
    {ok, #state{socket=Socket, host=Host, port=Port, interval=Interval}}.

handle_call(_Req, _From, State) -> {ok, reply, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) ->
    erlang:send_after(State#state.interval, self(), send),
    catch send(State), % prevent crash on non-existed methods and send error
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
send(State) ->
    Metrics = folsom_metrics:get_metrics_info(),
    [gen_udp:send(State#state.socket,
                  State#state.host,
                  State#state.port,
                  Name++" "++Val++" "++Ts++"\n") || [Name, Val, Ts] <- format_metrics(Metrics)].

%% choose and format metrics to send
format_metrics([{Name, [{type, Type}]}| Metrics]) when Type == counter; Type == gauge ->
    Value = folsom_metrics:get_metric_value(Name),
    [format_metric(Name, Value)| format_metrics(Metrics)];
format_metrics([{Name, [{type, Type}]}| Metrics]) when Type == histogram; Type == duration ->
    Stats = folsom_metrics:get_histogram_statistics(Name),
    Percent = proplists:get_value(percentile, Stats),
    [format_pl_metric(Name, min, Stats),
     format_pl_metric(Name, max, Stats),
     format_pl_metric(Name, harmonic_mean, Stats),
     format_pl_metric([Name, percent], 50, Percent),
     format_pl_metric([Name, percent], 75, Percent),
     format_pl_metric([Name, percent], 90, Percent),
     format_pl_metric([Name, percent], 99, Percent)| format_metrics(Metrics)];
format_metrics([{Name, [{type, spiral}]}| Metrics]) ->
    Stats = folsom_metrics:get_metric_value(Name),
    [format_pl_metric(Name, count, Stats),
     format_pl_metric(Name, one, Stats)| format_metrics(Metrics)];
format_metrics([{Name, [{type, meter}]}| Metrics]) ->
    Stats = folsom_metrics:get_metric_value(Name),
    Accel = proplists:get_value(acceleration, Stats),
    [format_pl_metric(Name, count, Stats),
     format_pl_metric(Name, one, Stats),
     format_pl_metric(Name, five, Stats),
     format_pl_metric(Name, fifteen, Stats),
     format_pl_metric(Name, day, Stats),
     format_pl_metric(Name, mean, Stats),
     format_pl_metric([Name, accel], one_to_five, Accel),
     format_pl_metric([Name, accel], five_to_fifteen, Accel),
     format_pl_metric([Name, accel], one_to_fifteen, Accel)| format_metrics(Metrics)];
format_metrics([{Name, [{type, meter_reader}]}| Metrics]) ->
    Stats = folsom_metrics:get_metric_value(Name),
    Accel = proplists:get_value(acceleration, Stats),
    [format_pl_metric(Name, one, Stats),
     format_pl_metric(Name, five, Stats),
     format_pl_metric(Name, fifteen, Stats),
     format_pl_metric(Name, mean, Stats),
     format_pl_metric([Name, accel], one_to_five, Accel),
     format_pl_metric([Name, accel], five_to_fifteen, Accel),
     format_pl_metric([Name, accel], one_to_fifteen, Accel)| format_metrics(Metrics)];
format_metrics([_| Metrics]) -> format_metrics(Metrics); % 'history' metric skipped here
format_metrics([]) -> [].

%% format name, value, timestamp
format_metric(Name, Val) ->
    [make_name(Name), make_value(Val), timestamp()].

%% format name, value, timestamp using proplist
format_pl_metric(Name, Key, Proplist) ->
    format_metric([Name, Key], proplists:get_value(Key, Proplist)).

%% Deep join name list elements with dot. String elements not supported
make_name(Name) -> make_name(Name, []).
make_name([H| T], Acc) when is_tuple(H) ->   make_name(tuple_to_list(H) ++ T, Acc);
make_name([H| T], Acc) when is_list(H) ->    make_name(H ++ T, Acc);
make_name([H| T], Acc) when is_integer(H) -> make_name(T, [integer_to_list(H)| Acc]);
make_name([H| T], Acc) when is_atom(H) ->    make_name(T, [atom_to_list(H)| Acc]);
make_name([H| T], Acc) when is_binary(H) ->  make_name(T, [binary_to_list(H)| Acc]);
make_name([], Acc) -> string:join(lists:reverse(Acc), ".").

make_value(Val) when is_integer(Val) -> integer_to_list(Val);
make_value(Val) when is_float(Val) -> float_to_list(Val);
make_value(_) -> "not_a_num".

timestamp() ->
    {M, S, _} = os:timestamp(),
    integer_to_list(M * 1000000 + S).
