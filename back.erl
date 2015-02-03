-module(back).
-include("http.hrl").

-export([
		back_start/0,
		back_process/1
	]).

back_start() ->
    back_start(['0.0.0.0', ?BACK_PORT]).

back_start(Args) ->
    % prevent disconnect when run in ssh
    spawn(util, heart, []),
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
    	case  gen_tcp:recv(Front,4) of 
            {ok,Packet} ->
                case Packet of
                    <<1,1,0,0>> ->
                        %% heart beat package
                        back_process(Front);
                    <<0,1,0,1>> ->
                        %% start to communicate
                            From = self(),
                            {ok, Remote} = gen_tcp:connect(?PROXY_IP,
                                      ?PROXY_PORT,
                                       [{active, false}, binary, {nodelay, true}],
                                       ?CONNECT_TIMEOUT),

                            spawn(util, forward, [Front, Remote, From]),
                            spawn(util, forward, [Remote, Front, From]),
                            receive
                                {close} ->
                                    gen_tcp:close(Front),
                                    gen_tcp:close(Remote)
                            end
                end;            
            {error,_Reason} ->
                gen_tcp:close(Front)
        end.  