-module(http).

-define(FRONT_PORT, 1234).
-define(BACK_PORT, 1235).

-define(PROXY_IP,'106.187.*').
-define(PROXY_PORT,1234).
-define(CONNECT_TIMEOUT, 5000).

-export([
		back_start/0,
		flip/1,
		front_start/0,
		%%front_process/1,
		back_process/1,
		forward/3,
		forward/4,
		flip_recv/3,
		flip_send/2,
		heart/0,
		start/0,
        front_preconnection_backend/3,
        front_idle_connection/0,
        front_idle_connection/2,
        front_accept/1
	]).


flip(L) ->
    flip(L, 16#66).

flip(L,V) ->
    << <<(X bxor V)>> ||  <<X>> <= L   >> .


flip_recv(Client, Length, Timeout) ->
    {ok, Data} = gen_tcp:recv(Client, Length, Timeout),
    {ok, flip(Data)}.

flip_send(Client, Data) ->
    gen_tcp:send(Client, flip(Data)).


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
        %% recv heart beat
		case  gen_tcp:recv(Front,4) of 
            {ok,Packet} ->
                case Packet of
                    <<1,1,0,0>> ->
                        %% heart beat package
                        %%io:format("heart beat received~n"),
                        back_process(Front);
                    <<0,1,0,1>> ->
                        %% start to communicate
                            From = self(),
                            {ok, Remote} = gen_tcp:connect(?PROXY_IP,
                                      ?PROXY_PORT,
                                       [{active, false}, binary, {nodelay, true}],
                                       ?CONNECT_TIMEOUT),

                            spawn(?MODULE, forward, [Front, Remote, From]),
                            spawn(?MODULE, forward, [Remote, Front, From]),
                            %%io:format("start communicate~n"),
                            receive
                                {close} ->
                                    gen_tcp:close(Front),
                                    gen_tcp:close(Remote)
                            end
                end;            
            {error,Reason} ->
                io:format("Heart beat error ~p~n",[Reason])
        end            
    catch
        Error:CReason ->
            io:format("~p ~p ~p ~p.~n", [Front, Error, CReason, erlang:get_stacktrace()]),
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


    Pool = spawn(?MODULE,front_preconnection_backend,[self(),[],50]),
    register(pool,Pool),

    spawn(?MODULE,front_accept,[Socket]),

    receive 
        {close} ->
            io:format("Application Closed~n")
    end.


front_accept(Socket) ->
    {ok, Client} = gen_tcp:accept(Socket),
    pool ! {connect,Client},
    front_accept(Socket).

start() ->
	spawn(?MODULE, back_start, []),
    spawn(?MODULE, front_start, []),
    receive
        {close} ->
            exit({done})
    end.




front_idle_connection() ->
    case gen_tcp:connect(?PROXY_IP,
                       ?BACK_PORT,
                       [{active, false}, binary, {nodelay, true}],
                       ?CONNECT_TIMEOUT) of
        {ok,Remote} ->
            Child = spawn(?MODULE,front_idle_connection,[self(),Remote]),
            {ok,Child};
        _ ->
            {error,"Create pool socket error"}
    end.            



front_idle_connection(Parent,Backend) ->
    receive
        {socket,Front} ->
            %%io:format("communicate a socket ~n"),

            ok = gen_tcp:send(Backend,<<0,1,0,1>>),

            spawn(?MODULE, forward, [Front, Backend, self()]),
            spawn(?MODULE, forward, [Backend, Front, self()]),

            receive
                {close} ->
                    gen_tcp:close(Front),
                    gen_tcp:close(Backend)
            end  
    after
        5000 ->
            %% heart beat
            case gen_tcp:send(Backend,<<1,1,0,0>>) of
                ok ->
                    %%io:format("heart beat send~n"),
                    front_idle_connection(Parent,Backend);
                {error,Reason} ->
                    io:format("heart beat error ~p~n",[Reason]),
                    Parent ! {closed,self()}
            end               
    end.         


front_init_preconnection(List,0) ->
    List;
front_init_preconnection(List,Num)->   
    case front_idle_connection() of 
        {ok,Child} ->
            NewList = lists:append(List,[Child]),
            NewNum = Num - 1,
            %%io:format("created a socket ~n"),
            front_init_preconnection(NewList,NewNum);
        _ ->
            timer:sleep(2000),
            front_init_preconnection(List,Num)
    end.        
    
front_preconnection_backend(Parent,List,NumNeed) ->
    NewList = front_init_preconnection(List,NumNeed),

    %%io:format("~p~n",[NewList]),
    receive
        {connect,Front} ->
            [Child | CNewList] = NewList,
            Child ! {socket,Front},
            %%io:format("dispached a socket ~n"),
            front_preconnection_backend(Parent,CNewList,1);
        {closed,Child} ->
            CNewList = lists:delete(Child,NewList),
            front_preconnection_backend(Parent,CNewList,1);    
        _ ->
           Parent ! {close}     
    after
        10000 ->
            front_preconnection_backend(Parent,NewList,0)
    end. 