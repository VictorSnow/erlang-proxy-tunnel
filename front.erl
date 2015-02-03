-module(front).

-include("http.hrl").


-export([
		front_start/0,
		front_idle_connection/0,
		front_idle_connection/2,
		front_preconnection_backend/3,
		front_accept/1
	]).

%% front server
front_start() ->
    front_start(['0.0.0.0', ?FRONT_PORT]).

front_start(Args) ->
    % prevent disconnect when run in ssh
    spawn(util, heart, []),
    [BackAddressStr, BackPortStr] = Args,
    BackPort = BackPortStr,
    {ok, BackAddress} = inet:getaddr(BackAddressStr, inet),
    io:format("front listen at ~s:~p.~n", [BackAddressStr, BackPort]),
    {ok, Socket} = gen_tcp:listen(BackPort, [{reuseaddr, true},
                                             {active, false},
                                             {ifaddr, BackAddress},
                                             {nodelay, true},
                                             binary]),


    Pool = spawn(?MODULE,front_preconnection_backend,[self(),[],?POOL_SIZE]),
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

    case ?POOL_SIZE-NumNeed of
        0 ->
            NewList = front_init_preconnection(List,1),
            front_preconnection_backend(Parent,NewList,NumNeed-1);
        _ ->
            receive
                {connect,Front} ->
                    [Child | NewList] = List,
                    Child ! {socket,Front},
                    front_preconnection_backend(Parent,NewList,NumNeed+1);
                {closed,Child} ->
                    io:format("~p~n",[[remove,Child]]),
                    NewList = lists:delete(Child,List),
                    front_preconnection_backend(Parent,NewList,NumNeed+1);    
                _ ->
                   Parent ! {close}
            after
                0 ->
                    case NumNeed of
                        0 ->
                            timer:sleep(1000),
                            front_preconnection_backend(Parent,List,NumNeed);
                        _ ->
                            NewList = front_init_preconnection(List,1),
                            front_preconnection_backend(Parent,NewList,NumNeed-1)
                    end            
            end
    end.   