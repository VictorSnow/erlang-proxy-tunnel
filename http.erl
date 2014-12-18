-module(http).

-define(FRONT_PORT, 1234).
-define(BACK_PORT, 1235).

-define(PROXY_IP,'192.157.*.*').
-define(PROXY_PORT,1234).
-define(CONNECT_TIMEOUT, 5000).

-export([
		back_start/0,
		flip/1,
		front_start/0,
		front_process/1,
		back_process/1,
		forward/3,
		forward/4,
		flip_recv/3,
		flip_send/2,
		heart/0,
		start/0
	]).


flip(L) ->
    flip(L, 16#66).

flip(L, V) ->
    <<  << (X bxor V) >> ||  <<X>> <=  L >>.

flip_recv(Client, Length, Timeout) ->
    {ok, Data} = gen_tcp:recv(Client, Length, Timeout),
    {ok, flip(Data)}.

flip_send(Client, Data) ->
    gen_tcp:send(Client, flip(Data)).


atoms_to_lists(L, R) ->
    lists:reverse(atoms_to_lists2(L, R)).

atoms_to_lists2([X|L], R) ->
    atoms_to_lists2(L, [atom_to_list(X)|R]);
atoms_to_lists2([], R) ->
    R.

heart() ->
    timer:sleep(10000),
    io:format(".~n"),
    heart().


back_start() ->
    back_start(['0.0.0.0', ?BACK_PORT]).

back_start(Args) ->
    % prevent disconnect when run in ssh
    spawn(?MODULE, heart, []),
    [BackAddressStr, BackPortStr] = Args,
   	BackPort = BackPortStr,
    {ok, BackAddress} = inet:getaddr(BackAddressStr, inet),
    io:format("back listen at ~s:~p.~n", [BackAddressStr, BackPort]),
    {ok, Socket} = gen_tcp:listen(BackPort, [{reuseaddr, true},
                                             {active, false},
                                             {ifaddr, BackAddress},
                                             {nodelay, true},
                                             binary]),
    back_accept(Socket).


back_accept(Socket) ->
    {ok, Client} = gen_tcp:accept(Socket),
    spawn(?MODULE, back_process, [Client]),
    back_accept(Socket).


back_process(Front) ->
    try
        From = self(),

        %% connection to proxy server
		{ok, Remote} = gen_tcp:connect(?PROXY_IP,
                                   ?PROXY_PORT,
                                   [{active, false}, binary, {nodelay, true}],
                                   ?CONNECT_TIMEOUT),

        spawn(?MODULE, forward, [Front, Remote, From]),
        spawn(?MODULE, forward, [Remote, Front, From]),

        receive
            {close} ->
                gen_tcp:close(Front),
                gen_tcp:close(Remote)
        end
    catch
        Error:Reason ->
            io:format("~p ~p ~p ~p.~n", [Front, Error, Reason, erlang:get_stacktrace()]),
            gen_tcp:close(Front)
    end.

forward(Client, Remote, From) ->
    forward(Client, Remote, From, fun(_Args) -> ok end).

forward(Client, Remote, From, Fun) ->
    try
        {ok, Packet} = gen_tcp:recv(Client, 0),
        ok = flip_send(Remote, Packet),
        Fun([Client, Remote, Packet]),
        ok
    catch
        Error:Reason ->
            From ! {close},
            exit({Error, Reason})
    end,
    forward(Client, Remote, From, Fun).



%% front server
front_start() ->
    front_start(['0.0.0.0', ?FRONT_PORT]).

front_start(Args) ->
    % prevent disconnect when run in ssh
    spawn(?MODULE, heart, []),
    [BackAddressStr, BackPortStr] = Args,
    BackPort = BackPortStr,
    {ok, BackAddress} = inet:getaddr(BackAddressStr, inet),
    io:format("front listen at ~s:~p.~n", [BackAddressStr, BackPort]),
    {ok, Socket} = gen_tcp:listen(BackPort, [{reuseaddr, true},
                                             {active, false},
                                             {ifaddr, BackAddress},
                                             {nodelay, true},
                                             binary]),
    front_accept(Socket).


front_accept(Socket) ->
    {ok, Client} = gen_tcp:accept(Socket),
    spawn(?MODULE, front_process, [Client]),
    front_accept(Socket).


front_process(Front) ->
    try
        From = self(),

        %% connection to proxy server
		{ok, Remote} = gen_tcp:connect(?PROXY_IP,
                                   ?BACK_PORT,
                                   [{active, false}, binary, {nodelay, true}],
                                   ?CONNECT_TIMEOUT),

        spawn(?MODULE, forward, [Front, Remote, From]),
        spawn(?MODULE, forward, [Remote, Front, From]),

        receive
            {close} ->
                gen_tcp:close(Front),
                gen_tcp:close(Remote)
        end
    catch
        Error:Reason ->
            io:format("~p ~p ~p ~p.~n", [Front, Error, Reason, erlang:get_stacktrace()]),
            gen_tcp:close(Front)
    end.


start() ->
	spawn(?MODULE, back_start, []),
    spawn(?MODULE, front_start, []),
    receive
        {close} ->
            exit({done})
    end.
