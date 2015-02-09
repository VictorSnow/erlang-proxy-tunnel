-module(util).

-export([
		forward/3,
		flip_send/2,
		heart/0,
		main/0
	]).

forward(Client, Remote, From) ->
    case gen_tcp:recv(Client,0) of
        {ok,Packet} ->
            case flip_send(Remote, Packet) of
                ok ->
                    forward(Client,Remote,From);
                error ->
                    From ! {close}
            end;        
        {error,_} ->
            From ! {close}
    end. 

flip(L) ->
    flip(L, 16#66).

flip(L,V) ->
    << <<(X bxor V)>> ||  <<X>> <= L   >> .

flip_send(Client,Data) ->
    flip_send(Client,Data,5).


flip_send(Client,Data,0) ->
    gen_tcp:send(Client, flip(Data));

flip_send(Client, Data,RetryTime) ->
    case gen_tcp:send(Client, flip(Data)) of
        ok ->
            ok;
        {error,etimeout} ->
            io:format("Retry To Send Packet"),
            flip_send(Client,Data,RetryTime-1);
        {error,_Reason} ->
            error    
    end.            

heart() ->
    timer:sleep(10000),
    io:format(".~n"),
    heart().    

main() ->
	Data = flip(<<11111111,1,0,0,1,0,0,0>>),
	io:format("~p~n",[Data]),
	io:format("~p~n",[flip(Data)]).   