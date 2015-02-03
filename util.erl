-module(util).

-export([
		forward/3,
		flip_send/2,
		heart/0
	]).

forward(Client, Remote, From) ->
    case gen_tcp:recv(Client,0) of
        {ok,Packet} ->
            flip_send(Remote, Packet),
            forward(Client,Remote,From);
        {error,_} ->
            From ! {close}
    end. 

flip(L) ->
    flip(L, 16#66).

flip(L,V) ->
    << <<(X bxor V)>> ||  <<X>> <= L   >> .

flip_send(Client, Data) ->
    gen_tcp:send(Client, flip(Data)).

heart() ->
    timer:sleep(10000),
    io:format(".~n"),
    heart().    