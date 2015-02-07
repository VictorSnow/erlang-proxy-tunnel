-module(front).

-include("http.hrl").


-export([
		front_server/0,
        front_start/1,
		front_idle_connection/0,
		front_idle_connection/2,
		front_preconnection_backend/3,
		front_accept/2
	]).

front_server() ->
    Pool = spawn(?MODULE,front_preconnection_backend,[self(),[],?POOL_SIZE]),
    register(pool,Pool),
    front_server_start(?FRONT_PORT),
    receive 
        {close} ->
            io:format("closed")
    end.        

front_server_start([]) ->
    [];

front_server_start(Ports) ->
    [[Front,Back]|Remain] = Ports,
    spawn(?MODULE,front_start,[['0.0.0.0',Front,Back]]),
    front_server_start(Remain).

%% front server
%%front_server_start(Front,Back) ->
%%    front_start(['0.0.0.0', ?FRONT_PORT,1234]).
    %%spawn(?MODULE,front_start,['0.0.0.0',Front,Back]),
       


front_start(Args) ->
    % prevent disconnect when run in ssh
    spawn(util, heart, []),
    [FrontAddressStr, FrontPort,BackPort] = Args,
    %% BackPort = BackPortStr,
    {ok, FrontAddress} = inet:getaddr(FrontAddressStr, inet),
    io:format("front listen at ~s:~p.~n", [FrontAddressStr, FrontPort]),
    {ok, Socket} = gen_tcp:listen(FrontPort, [{reuseaddr, true},
                                             {active, false},
                                             {ifaddr, FrontAddress},
                                             {nodelay, true},
                                             binary]),

    spawn(?MODULE,front_accept,[Socket,BackPort]),

    receive 
        {close} ->
            io:format("Application Closed~n")
    end.


front_accept(Socket,BackPort) ->
    {ok, Client} = gen_tcp:accept(Socket),
    pool ! {connect,Client,BackPort},
    front_accept(Socket,BackPort).


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
        {socket,Front,Port} ->
            %%io:format("communicate a socket ~n"),

            ok = gen_tcp:send(Backend,<<0,1,0,1,Port:16>>),

            spawn(util, forward, [Front, Backend, self()]),
            spawn(util, forward, [Backend, Front, self()]),

            receive
                {close} ->
                    %%io:format("~p~n",[[closed,Front]]),
                    gen_tcp:close(Front),
                    gen_tcp:close(Backend)
            end  
    after
        10000 ->
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
front_init_preconnection(List,1)->   
    case front_idle_connection() of 
        {ok,Child} ->
            io:format("init Socket~n"),
            lists:append(List,[Child]);
            %%NewNum = Num - 1,
            %%front_init_preconnection(NewList,NewNum);
        _ ->
            timer:sleep(1000),
            front_init_preconnection(List,1)
    end.        
    
front_preconnection_backend(Parent,List,NumNeed) ->
    
    %%io:format("current pool size ~p~n",[?POOL_SIZE-NumNeed]),

    case NumNeed of
    	0 ->
    		WaitInterval = 5000;
    	_ ->
    		WaitInterval = 0
    end,			


    case ?POOL_SIZE-NumNeed of
        0 ->
            NewList = front_init_preconnection(List,1),
            front_preconnection_backend(Parent,NewList,NumNeed-1);
        _ ->
            receive
                {connect,Front,Port} ->
                    [Child | NewList] = List,
                    Child ! {socket,Front,Port},
                    front_preconnection_backend(Parent,NewList,NumNeed+1);
                {closed,Child} ->
                    io:format("~p~n",[[remove,Child]]),
                    NewList = lists:delete(Child,List),
                    front_preconnection_backend(Parent,NewList,NumNeed+1);    
                _ ->
                   Parent ! {close}
            after
                WaitInterval ->
                    case NumNeed of
                        0 ->
                            front_preconnection_backend(Parent,List,NumNeed);
                        _ ->
                            NewList = front_init_preconnection(List,1),
                            front_preconnection_backend(Parent,NewList,NumNeed-1)
                    end            
            end
    end.   
