%%%-------------------------------------------------------------------
%%% Created :  8 Dec 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(ejabberd_c2s).
-behaviour(xmpp_stream_in).
-behaviour(ejabberd_config).
-behaviour(ejabberd_socket).

-protocol({rfc, 6121}).

%% ejabberd_socket callbacks
-export([start/2, start_link/2, socket_type/0]).
%% ejabberd_config callbacks
-export([opt_type/1, transform_listen_option/2]).
%% xmpp_stream_in callbacks
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).
-export([tls_options/1, tls_required/1, tls_verify/1, tls_enabled/1,
	 compress_methods/1, bind/2, sasl_mechanisms/2,
	 get_password_fun/1, check_password_fun/1, check_password_digest_fun/1,
	 unauthenticated_stream_features/1, authenticated_stream_features/1,
	 handle_stream_start/2, handle_stream_end/2,
	 handle_unauthenticated_packet/2, handle_authenticated_packet/2,
	 handle_auth_success/4, handle_auth_failure/4, handle_send/3,
	 handle_recv/3, handle_cdata/2, handle_unbinded_packet/2]).
%% Hooks
-export([handle_unexpected_cast/2,
	 reject_unauthenticated_packet/2, process_closed/2,
	 process_terminated/2, process_info/2]).
%% API
-export([get_presence/1, get_subscription/2, get_subscribed/1,
	 open_session/1, call/3, send/2, close/1, close/2, stop/1,
	 reply/2, copy_state/2, set_timeout/2, add_hooks/1]).

-include("ejabberd.hrl").
-include("xmpp.hrl").
-include("logger.hrl").

-define(SETS, gb_sets).

-type state() :: map().
-export_type([state/0]).

%%%===================================================================
%%% ejabberd_socket API
%%%===================================================================
start(SockData, Opts) ->
    case proplists:get_value(supervisor, Opts, true) of
	true ->
	    supervisor:start_child(ejabberd_c2s_sup, [SockData, Opts]);
	_ ->
	    xmpp_stream_in:start(?MODULE, [SockData, Opts],
				 ejabberd_config:fsm_limit_opts(Opts))
    end.

start_link(SockData, Opts) ->
    xmpp_stream_in:start_link(?MODULE, [SockData, Opts],
			      ejabberd_config:fsm_limit_opts(Opts)).

socket_type() ->
    xml_stream.

%%%===================================================================
%%% Common API
%%%===================================================================
-spec call(pid(), term(), non_neg_integer() | infinity) -> term().
call(Ref, Msg, Timeout) ->
    xmpp_stream_in:call(Ref, Msg, Timeout).

reply(Ref, Reply) ->
    xmpp_stream_in:reply(Ref, Reply).

-spec get_presence(pid()) -> presence().
get_presence(Ref) ->
    call(Ref, get_presence, 1000).

-spec get_subscription(jid() | ljid(), state()) -> both | from | to | none.
get_subscription(#jid{} = From, State) ->
    get_subscription(jid:tolower(From), State);
get_subscription(LFrom, #{pres_f := PresF, pres_t := PresT}) ->
    LBFrom = jid:remove_resource(LFrom),
    F = ?SETS:is_element(LFrom, PresF) orelse ?SETS:is_element(LBFrom, PresF),
    T = ?SETS:is_element(LFrom, PresT) orelse ?SETS:is_element(LBFrom, PresT),
    if F and T -> both;
       F -> from;
       T -> to;
       true -> none
    end.

-spec get_subscribed(pid()) -> [ljid()].
%% Return list of all available resources of contacts
get_subscribed(Ref) ->
    call(Ref, get_subscribed, 1000).

close(Ref) ->
    xmpp_stream_in:close(Ref).

close(Ref, SendTrailer) ->
    xmpp_stream_in:close(Ref, SendTrailer).

stop(Ref) ->
    xmpp_stream_in:stop(Ref).

-spec send(pid(), xmpp_element()) -> ok;
	  (state(), xmpp_element()) -> state().
send(Pid, Pkt) when is_pid(Pid) ->
    xmpp_stream_in:send(Pid, Pkt);
send(#{lserver := LServer} = State, Pkt) ->
    Pkt1 = fix_from_to(Pkt, State),
    case ejabberd_hooks:run_fold(c2s_filter_send, LServer, {Pkt1, State}, []) of
	{drop, State1} -> State1;
	{Pkt2, State1} -> xmpp_stream_in:send(State1, Pkt2)
    end.

-spec set_timeout(state(), timeout()) -> state().
set_timeout(State, Timeout) ->
    xmpp_stream_in:set_timeout(State, Timeout).

-spec add_hooks(binary()) -> ok.
add_hooks(Host) ->
    ejabberd_hooks:add(c2s_closed, Host, ?MODULE, process_closed, 100),
    ejabberd_hooks:add(c2s_terminated, Host, ?MODULE,
		       process_terminated, 100),
    ejabberd_hooks:add(c2s_unauthenticated_packet, Host, ?MODULE,
		       reject_unauthenticated_packet, 100),
    ejabberd_hooks:add(c2s_handle_info, Host, ?MODULE,
		       process_info, 100),
    ejabberd_hooks:add(c2s_handle_cast, Host, ?MODULE,
		       handle_unexpected_cast, 100).

%% Copies content of one c2s state to another.
%% This is needed for session migration from one pid to another.
-spec copy_state(state(), state()) -> state().
copy_state(#{owner := Owner} = NewState,
	   #{jid := JID, resource := Resource, sid := {Time, _},
	     auth_module := AuthModule, lserver := LServer,
	     pres_t := PresT, pres_a := PresA,
	     pres_f := PresF} = OldState) ->
    State1 = case OldState of
		 #{pres_last := Pres, pres_timestamp := PresTS} ->
		     NewState#{pres_last => Pres, pres_timestamp => PresTS};
		 _ ->
		     NewState
	     end,
    Conn = get_conn_type(State1),
    State2 = State1#{jid => JID, resource => Resource,
		     conn => Conn,
		     sid => {Time, Owner},
		     auth_module => AuthModule,
		     pres_t => PresT, pres_a => PresA,
		     pres_f => PresF},
    ejabberd_hooks:run_fold(c2s_copy_session, LServer, State2, [OldState]).

-spec open_session(state()) -> {ok, state()} | state().
open_session(#{user := U, server := S, resource := R,
	       sid := SID, ip := IP, auth_module := AuthModule} = State) ->
    JID = jid:make(U, S, R),
    change_shaper(State),
    Conn = get_conn_type(State),
    State1 = State#{conn => Conn, resource => R, jid => JID},
    Prio = try maps:get(pres_last, State) of
	       Pres -> get_priority_from_presence(Pres)
	   catch _:{badkey, _} ->
		   undefined
	   end,
    Info = [{ip, IP}, {conn, Conn}, {auth_module, AuthModule}],
    ejabberd_sm:open_session(SID, U, S, R, Prio, Info),
    xmpp_stream_in:establish(State1).

%%%===================================================================
%%% Hooks
%%%===================================================================
process_info(#{lserver := LServer} = State,
	     {route, From, To, Packet0}) ->
    Packet = xmpp:set_from_to(Packet0, From, To),
    {Pass, State1} = case Packet of
			 #presence{} ->
			     process_presence_in(State, Packet);
			 #message{} ->
			     process_message_in(State, Packet);
			 #iq{} ->
			     process_iq_in(State, Packet)
		     end,
    if Pass ->
	    {Packet1, State2} = ejabberd_hooks:run_fold(
				  user_receive_packet, LServer,
				  {Packet, State1}, []),
	    case Packet1 of
		drop -> State2;
		_ -> send(State2, Packet1)
	    end;
       true ->
	    State1
    end;
process_info(State, force_update_presence) ->
    try maps:get(pres_last, State) of
	Pres -> process_self_presence(State, Pres)
    catch _:{badkey, _} ->
	    State
    end;
process_info(State, Info) ->
    ?WARNING_MSG("got unexpected info: ~p", [Info]),
    State.

handle_unexpected_cast(State, Msg) ->
    ?WARNING_MSG("got unexpected cast: ~p", [Msg]),
    State.

reject_unauthenticated_packet(State, _Pkt) ->
    Err = xmpp:serr_not_authorized(),
    send(State, Err).

process_closed(State, Reason) ->
    stop(State#{stop_reason => Reason}).

process_terminated(#{sockmod := SockMod, socket := Socket, jid := JID} = State,
		   Reason) ->
    Status = format_reason(State, Reason),
    ?INFO_MSG("(~s) Closing c2s session for ~s: ~s",
	      [SockMod:pp(Socket), jid:to_string(JID), Status]),
    State1 = case maps:is_key(pres_last, State) of
		 true ->
		     Pres = #presence{type = unavailable,
				      status = xmpp:mk_text(Status),
				      from = JID,
				      to = jid:remove_resource(JID)},
		     broadcast_presence_unavailable(State, Pres);
		 false ->
		     State
	     end,
    bounce_message_queue(),
    State1;
process_terminated(State, _Reason) ->
    State.

%%%===================================================================
%%% xmpp_stream_in callbacks
%%%===================================================================
tls_options(#{lserver := LServer, tls_options := DefaultOpts}) ->
    TLSOpts1 = case ejabberd_config:get_option(
		      {c2s_certfile, LServer},
		      fun iolist_to_binary/1,
		      ejabberd_config:get_option(
			{domain_certfile, LServer},
			fun iolist_to_binary/1)) of
		   undefined -> [];
		   CertFile -> lists:keystore(certfile, 1, DefaultOpts,
					      {certfile, CertFile})
	       end,
    TLSOpts2 = case ejabberd_config:get_option(
                      {c2s_ciphers, LServer},
		      fun iolist_to_binary/1) of
                   undefined -> TLSOpts1;
                   Ciphers -> lists:keystore(ciphers, 1, TLSOpts1,
					     {ciphers, Ciphers})
               end,
    TLSOpts3 = case ejabberd_config:get_option(
                      {c2s_protocol_options, LServer},
                      fun (Options) -> str:join(Options, <<$|>>) end) of
                   undefined -> TLSOpts2;
                   ProtoOpts -> lists:keystore(protocol_options, 1, TLSOpts2,
					       {protocol_options, ProtoOpts})
               end,
    TLSOpts4 = case ejabberd_config:get_option(
                      {c2s_dhfile, LServer},
		      fun iolist_to_binary/1) of
                   undefined -> TLSOpts3;
                   DHFile -> lists:keystore(dhfile, 1, TLSOpts3,
					    {dhfile, DHFile})
               end,
    TLSOpts5 = case ejabberd_config:get_option(
		      {c2s_cafile, LServer},
		      fun iolist_to_binary/1) of
		   undefined -> TLSOpts4;
		   CAFile -> lists:keystore(cafile, 1, TLSOpts4,
					    {cafile, CAFile})
	       end,
    case ejabberd_config:get_option(
	   {c2s_tls_compression, LServer},
	   fun(B) when is_boolean(B) -> B end) of
	undefined -> TLSOpts5;
	false -> [compression_none | TLSOpts5];
	true -> lists:delete(compression_none, TLSOpts5)
    end.

tls_required(#{tls_required := TLSRequired}) ->
    TLSRequired.

tls_verify(#{tls_verify := TLSVerify}) ->
    TLSVerify.

tls_enabled(#{tls_enabled := TLSEnabled,
	      tls_required := TLSRequired,
	      tls_verify := TLSVerify}) ->
    TLSEnabled or TLSRequired or TLSVerify.

compress_methods(#{zlib := true}) ->
    [<<"zlib">>];
compress_methods(_) ->
    [].

unauthenticated_stream_features(#{lserver := LServer}) ->
    ejabberd_hooks:run_fold(c2s_pre_auth_features, LServer, [], [LServer]).

authenticated_stream_features(#{lserver := LServer}) ->
    ejabberd_hooks:run_fold(c2s_post_auth_features, LServer, [], [LServer]).

sasl_mechanisms(Mechs, #{lserver := LServer}) ->
    Mechs1 = ejabberd_config:get_option(
	       {disable_sasl_mechanisms, LServer},
	       fun(V) when is_list(V) ->
		       lists:map(fun(M) -> str:to_upper(M) end, V);
		  (V) ->
		       [str:to_upper(V)]
	       end, []),
    Mechs2 = case ejabberd_auth_anonymous:is_sasl_anonymous_enabled(LServer) of
		 true -> Mechs1;
		 false -> [<<"ANONYMOUS">>|Mechs1]
	     end,
    Mechs -- Mechs2.

get_password_fun(#{lserver := LServer}) ->
    fun(U) ->
	    ejabberd_auth:get_password_with_authmodule(U, LServer)
    end.

check_password_fun(#{lserver := LServer}) ->
    fun(U, AuthzId, P) ->
	    ejabberd_auth:check_password_with_authmodule(U, AuthzId, LServer, P)
    end.

check_password_digest_fun(#{lserver := LServer}) ->
    fun(U, AuthzId, P, D, DG) ->
	    ejabberd_auth:check_password_with_authmodule(U, AuthzId, LServer, P, D, DG)
    end.

bind(<<"">>, State) ->
    bind(new_uniq_id(), State);
bind(R, #{user := U, server := S, access := Access, lang := Lang,
	  lserver := LServer, sockmod := SockMod, socket := Socket,
	  ip := IP} = State) ->
    case resource_conflict_action(U, S, R) of
	closenew ->
	    {error, xmpp:err_conflict(), State};
	{accept_resource, Resource} ->
	    JID = jid:make(U, S, Resource),
	    case acl:access_matches(Access,
				    #{usr => jid:split(JID), ip => IP},
				    LServer) of
		allow ->
		    State1 = open_session(State#{resource => Resource,
						 sid => ejabberd_sm:make_sid()}),
		    State2 = ejabberd_hooks:run_fold(
			       c2s_session_opened, LServer, State1, []),
		    ?INFO_MSG("(~s) Opened c2s session for ~s",
			      [SockMod:pp(Socket), jid:to_string(JID)]),
		    {ok, State2};
		deny ->
		    ejabberd_hooks:run(forbidden_session_hook, LServer, [JID]),
		    ?INFO_MSG("(~s) Forbidden c2s session for ~s",
			      [SockMod:pp(Socket), jid:to_string(JID)]),
		    Txt = <<"Denied by ACL">>,
		    {error, xmpp:err_not_allowed(Txt, Lang), State}
	    end
    end.

handle_stream_start(StreamStart, #{lserver := LServer} = State) ->
    case ejabberd_router:is_my_host(LServer) of
	false ->
	    send(State, xmpp:serr_host_unknown());
	true ->
	    change_shaper(State),
	    ejabberd_hooks:run_fold(
	      c2s_stream_started, LServer, State, [StreamStart])
    end.

handle_stream_end(Reason, #{lserver := LServer} = State) ->
    State1 = State#{stop_reason => Reason},
    ejabberd_hooks:run_fold(c2s_closed, LServer, State1, [Reason]).

handle_auth_success(User, Mech, AuthModule,
		    #{socket := Socket, sockmod := SockMod,
		      ip := IP, lserver := LServer} = State) ->
    ?INFO_MSG("(~s) Accepted c2s ~s authentication for ~s@~s by ~s backend from ~s",
	      [SockMod:pp(Socket), Mech, User, LServer,
	       ejabberd_auth:backend_type(AuthModule),
	       ejabberd_config:may_hide_data(jlib:ip_to_list(IP))]),
    State1 = State#{auth_module => AuthModule},
    ejabberd_hooks:run_fold(c2s_auth_result, LServer, State1, [true, User]).

handle_auth_failure(User, Mech, Reason,
		    #{socket := Socket, sockmod := SockMod,
		      ip := IP, lserver := LServer} = State) ->
    ?INFO_MSG("(~s) Failed c2s ~s authentication ~sfrom ~s: ~s",
	      [SockMod:pp(Socket), Mech,
	       if User /= <<"">> -> ["for ", User, "@", LServer, " "];
		  true -> ""
	       end,
	       ejabberd_config:may_hide_data(jlib:ip_to_list(IP)), Reason]),
    ejabberd_hooks:run_fold(c2s_auth_result, LServer, State, [false, User]).

handle_unbinded_packet(Pkt, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_unbinded_packet, LServer, State, [Pkt]).

handle_unauthenticated_packet(Pkt, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_unauthenticated_packet, LServer, State, [Pkt]).

handle_authenticated_packet(Pkt, #{lserver := LServer} = State) when not ?is_stanza(Pkt) ->
    ejabberd_hooks:run_fold(c2s_authenticated_packet,
			    LServer, State, [Pkt]);
handle_authenticated_packet(Pkt, #{lserver := LServer, jid := JID} = State) ->
    State1 = ejabberd_hooks:run_fold(c2s_authenticated_packet,
				     LServer, State, [Pkt]),
    #jid{luser = LUser} = JID,
    {Pkt1, State2} = ejabberd_hooks:run_fold(
		       user_send_packet, LServer, {Pkt, State1}, []),
    case Pkt1 of
	drop ->
	    State2;
	#presence{to = #jid{luser = LUser, lserver = LServer,
			    lresource = <<"">>}} ->
	    process_self_presence(State2, Pkt1);
	#presence{} ->
	    process_presence_out(State2, Pkt1);
	_ ->
	    check_privacy_then_route(State2, Pkt1)
    end.

handle_cdata(Data, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_cdata, LServer,
			    State, [Data]).

handle_recv(El, Pkt, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_recv, LServer, State, [El, Pkt]).

handle_send(Pkt, Result, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_send, LServer, State, [Pkt, Result]).

init([State, Opts]) ->
    Access = gen_mod:get_opt(access, Opts, fun acl:access_rules_validator/1, all),
    Shaper = gen_mod:get_opt(shaper, Opts, fun acl:shaper_rules_validator/1, none),
    TLSOpts1 = lists:filter(
		 fun({certfile, _}) -> true;
		    ({ciphers, _}) -> true;
		    ({dhfile, _}) -> true;
		    ({cafile, _}) -> true;
		    (_) -> false
		 end, Opts),
    TLSOpts2 = case lists:keyfind(protocol_options, 1, Opts) of
		   false -> TLSOpts1;
		   {_, OptString} ->
		       ProtoOpts = str:join(OptString, <<$|>>),
		       [{protocol_options, ProtoOpts}|TLSOpts1]
	       end,
    TLSOpts3 = case proplists:get_bool(tls_compression, Opts) of
                   false -> [compression_none | TLSOpts2];
                   true -> TLSOpts2
               end,
    TLSEnabled = proplists:get_bool(starttls, Opts),
    TLSRequired = proplists:get_bool(starttls_required, Opts),
    TLSVerify = proplists:get_bool(tls_verify, Opts),
    Zlib = proplists:get_bool(zlib, Opts),
    State1 = State#{tls_options => TLSOpts3,
		    tls_required => TLSRequired,
		    tls_enabled => TLSEnabled,
		    tls_verify => TLSVerify,
		    pres_a => ?SETS:new(),
		    pres_f => ?SETS:new(),
		    pres_t => ?SETS:new(),
		    zlib => Zlib,
		    lang => ?MYLANG,
		    server => ?MYNAME,
		    lserver => ?MYNAME,
		    access => Access,
		    shaper => Shaper},
    ejabberd_hooks:run_fold(c2s_init, {ok, State1}, [Opts]).

handle_call(get_presence, From, #{jid := JID} = State) ->
    Pres = try maps:get(pres_last, State)
	   catch _:{badkey, _} ->
		   BareJID = jid:remove_resource(JID),
		   #presence{from = JID, to = BareJID, type = unavailable}
	   end,
    reply(From, Pres),
    State;
handle_call(get_subscribed, From, #{pres_f := PresF} = State) ->
    reply(From, ?SETS:to_list(PresF)),
    State;
handle_call(Request, From, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(
      c2s_handle_call, LServer, State, [Request, From]).

handle_cast(Msg, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_cast, LServer, State, [Msg]).

handle_info(Info, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_info, LServer, State, [Info]).

terminate(Reason, #{sid := SID,
		    user := U, server := S, resource := R,
		    lserver := LServer} = State) ->
    case maps:is_key(pres_last, State) of
	true ->
	    Status = format_reason(State, Reason),
	    ejabberd_sm:close_session_unset_presence(SID, U, S, R, Status);
	false ->
	    ejabberd_sm:close_session(SID, U, S, R)
    end,
    ejabberd_hooks:run_fold(c2s_terminated, LServer, State, [Reason]);
terminate(Reason, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_terminated, LServer, State, [Reason]).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec process_iq_in(state(), iq()) -> {boolean(), state()}.
process_iq_in(State, #iq{} = IQ) ->
    case privacy_check_packet(State, IQ, in) of
	allow ->
	    {true, State};
	deny ->
	    route_error(IQ, xmpp:err_service_unavailable()),
	    {false, State}
    end.

-spec process_message_in(state(), message()) -> {boolean(), state()}.
process_message_in(State, #message{type = T} = Msg) ->
    case privacy_check_packet(State, Msg, in) of
	allow ->
	    {true, State};
	deny when T == groupchat; T == headline ->
	    ok;
	deny ->
	    case xmpp:has_subtag(Msg, #muc_user{}) of
		true ->
		    ok;
		false ->
		    route_error(Msg, xmpp:err_service_unavailable())
	    end,
	    {false, State}
    end.

-spec process_presence_in(state(), presence()) -> {boolean(), state()}.
process_presence_in(#{lserver := LServer, pres_a := PresA} = State0,
		    #presence{from = From, to = To, type = T} = Pres) ->
    State = ejabberd_hooks:run_fold(c2s_presence_in, LServer, State0, [Pres]),
    case T of
	probe ->
	    NewState = add_to_pres_a(State, From),
	    route_probe_reply(From, To, NewState),
	    {false, NewState};
	error ->
	    A = ?SETS:del_element(jid:tolower(From), PresA),
	    {true, State#{pres_a => A}};
	_ ->
	    case privacy_check_packet(State, Pres, in) of
		allow when T == error ->
		    {true, State};
		allow ->
		    NewState = add_to_pres_a(State, From),
		    {true, NewState};
		deny ->
		    {false, State}
	    end
    end.

-spec route_probe_reply(jid(), jid(), state()) -> ok.
route_probe_reply(From, To, #{lserver := LServer, pres_f := PresF,
			      pres_last := LastPres,
			      pres_timestamp := TS} = State) ->
    LFrom = jid:tolower(From),
    LBFrom = jid:remove_resource(LFrom),
    case ?SETS:is_element(LFrom, PresF)
	orelse ?SETS:is_element(LBFrom, PresF) of
	true ->
	    %% To is my JID
	    Packet = xmpp_util:add_delay_info(LastPres, To, TS),
	    case privacy_check_packet(State, Packet, out) of
		deny ->
		    ok;
		allow ->
		    ejabberd_hooks:run(presence_probe_hook,
				       LServer,
				       [From, To, self()]),
		    %% Don't route a presence probe to oneself
		    case From == To of
			false ->
			    route(xmpp:set_from_to(Packet, To, From));
			true ->
			    ok
		    end
	    end;
	false ->
	    ok
    end;
route_probe_reply(_, _, _) ->
    ok.

-spec process_presence_out(state(), presence()) -> state().
process_presence_out(#{user := User, server := Server, lserver := LServer,
		       jid := JID, lang := Lang, pres_a := PresA} = State,
		     #presence{from = From, to = To, type = Type} = Pres) ->
    LTo = jid:tolower(To),
    case privacy_check_packet(State, Pres, out) of
	deny ->
            ErrText = <<"Your active privacy list has denied "
			"the routing of this stanza.">>,
	    Err = xmpp:err_not_acceptable(ErrText, Lang),
	    xmpp_stream_in:send_error(State, Pres, Err);
	allow when Type == subscribe; Type == subscribed;
		   Type == unsubscribe; Type == unsubscribed ->
	    Access = gen_mod:get_module_opt(LServer, mod_roster, access,
					    fun(A) when is_atom(A) -> A end,
					    all),
	    MyBareJID = jid:remove_resource(JID),
	    case acl:match_rule(LServer, Access, MyBareJID) of
		deny ->
		    ErrText = <<"Denied by ACL">>,
		    Err = xmpp:err_forbidden(ErrText, Lang),
		    xmpp_stream_in:send_error(State, Pres, Err);
		allow ->
		    ejabberd_hooks:run(roster_out_subscription,
				       LServer,
				       [User, Server, To, Type]),
		    BareFrom = jid:remove_resource(From),
		    route(xmpp:set_from_to(Pres, BareFrom, To)),
		    State
	    end;
	allow when Type == error; Type == probe ->
	    route(Pres),
	    State;
	allow ->
	    route(Pres),
	    A = case Type of
		    available -> ?SETS:add_element(LTo, PresA);
		    unavailable -> ?SETS:del_element(LTo, PresA)
		end,
	    State#{pres_a => A}
    end.

-spec process_self_presence(state(), presence()) -> state().
process_self_presence(#{ip := IP, conn := Conn, lserver := LServer,
			auth_module := AuthMod, sid := SID,
			user := U, server := S,	resource := R} = State,
		      #presence{type = unavailable} = Pres) ->
    Status = xmpp:get_text(Pres#presence.status),
    Info = [{ip, IP}, {conn, Conn}, {auth_module, AuthMod}],
    ejabberd_sm:unset_presence(SID, U, S, R, Status, Info),
    {Pres1, State1} = ejabberd_hooks:run_fold(
			c2s_self_presence, LServer, {Pres, State}, []),
    State2 = broadcast_presence_unavailable(State1, Pres1),
    maps:remove(pres_last, maps:remove(pres_timestamp, State2));
process_self_presence(#{lserver := LServer} = State,
		      #presence{type = available} = Pres) ->
    PreviousPres = maps:get(pres_last, State, undefined),
    update_priority(State, Pres),
    {Pres1, State1} = ejabberd_hooks:run_fold(
			c2s_self_presence, LServer, {Pres, State}, []),
    State2 = State1#{pres_last => Pres1,
		     pres_timestamp => p1_time_compat:timestamp()},
    FromUnavailable = PreviousPres == undefined,
    broadcast_presence_available(State2, Pres1, FromUnavailable);
process_self_presence(State, _Pres) ->
    State.

-spec update_priority(state(), presence()) -> ok.
update_priority(#{ip := IP, conn := Conn, auth_module := AuthMod,
		  sid := SID, user := U, server := S, resource := R},
		Pres) ->
    Priority = get_priority_from_presence(Pres),
    Info = [{ip, IP}, {conn, Conn}, {auth_module, AuthMod}],
    ejabberd_sm:set_presence(SID, U, S, R, Priority, Pres, Info).

-spec broadcast_presence_unavailable(state(), presence()) -> state().
broadcast_presence_unavailable(#{pres_a := PresA} = State, Pres) ->
    JIDs = filter_blocked(State, Pres, PresA),
    route_multiple(State, JIDs, Pres),
    State#{pres_a => ?SETS:new()}.

-spec broadcast_presence_available(state(), presence(), boolean()) -> state().
broadcast_presence_available(#{pres_a := PresA, pres_f := PresF,
			       pres_t := PresT, jid := JID} = State,
			     Pres, _FromUnavailable = true) ->
    Probe = #presence{from = JID, type = probe},
    TJIDs = filter_blocked(State, Probe, PresT),
    FJIDs = filter_blocked(State, Pres, PresF),
    route_multiple(State, TJIDs, Probe),
    route_multiple(State, FJIDs, Pres),
    State#{pres_a => ?SETS:union(PresA, PresF)};
broadcast_presence_available(#{pres_a := PresA, pres_f := PresF} = State,
			     Pres, _FromUnavailable = false) ->
    JIDs = filter_blocked(State, Pres, ?SETS:intersection(PresA, PresF)),
    route_multiple(State, JIDs, Pres),
    State.

-spec check_privacy_then_route(state(), stanza()) -> state().
check_privacy_then_route(#{lang := Lang} = State, Pkt) ->
    case privacy_check_packet(State, Pkt, out) of
        deny ->
            ErrText = <<"Your active privacy list has denied "
			"the routing of this stanza.">>,
	    Err = xmpp:err_not_acceptable(ErrText, Lang),
	    xmpp_stream_in:send_error(State, Pkt, Err);
        allow ->
	    route(Pkt),
	    State
    end.

-spec privacy_check_packet(state(), stanza(), in | out) -> allow | deny.
privacy_check_packet(#{lserver := LServer} = State, Pkt, Dir) ->
    ejabberd_hooks:run_fold(privacy_check_packet, LServer, allow, [State, Pkt, Dir]).

-spec get_priority_from_presence(presence()) -> integer().
get_priority_from_presence(#presence{priority = Prio}) ->
    case Prio of
	undefined -> 0;
	_ -> Prio
    end.

-spec filter_blocked(state(), presence(), ?SETS:set()) -> [jid()].
filter_blocked(#{jid := From} = State, Pres, LJIDSet) ->
    ?SETS:fold(
       fun(LJID, Acc) ->
	       To = jid:make(LJID),
	       Pkt = xmpp:set_from_to(Pres, From, To),
	       case privacy_check_packet(State, Pkt, out) of
		   allow -> [To|Acc];
		   deny -> Acc
	       end
       end, [], LJIDSet).

-spec route(stanza()) -> ok.
route(Pkt) ->
    From = xmpp:get_from(Pkt),
    To = xmpp:get_to(Pkt),
    ejabberd_router:route(From, To, Pkt).

-spec route_error(stanza(), stanza_error()) -> ok.
route_error(Pkt, Err) ->
    From = xmpp:get_from(Pkt),
    To = xmpp:get_to(Pkt),
    ejabberd_router:route_error(To, From, Pkt, Err).

-spec route_multiple(state(), [jid()], stanza()) -> ok.
route_multiple(#{lserver := LServer}, JIDs, Pkt) ->
    From = xmpp:get_from(Pkt),
    ejabberd_router_multicast:route_multicast(From, LServer, JIDs, Pkt).

-spec resource_conflict_action(binary(), binary(), binary()) ->
				      {accept_resource, binary()} | closenew.
resource_conflict_action(U, S, R) ->
    OptionRaw = case ejabberd_sm:is_existing_resource(U, S, R) of
		    true ->
			ejabberd_config:get_option(
			  {resource_conflict, S},
			  fun(setresource) -> setresource;
			     (closeold) -> closeold;
			     (closenew) -> closenew;
			     (acceptnew) -> acceptnew
			  end);
		    false ->
			acceptnew
		end,
    Option = case OptionRaw of
		 setresource -> setresource;
		 closeold ->
		     acceptnew; %% ejabberd_sm will close old session
		 closenew -> closenew;
		 acceptnew -> acceptnew;
		 _ -> acceptnew %% default ejabberd behavior
	     end,
    case Option of
	acceptnew -> {accept_resource, R};
	closenew -> closenew;
	setresource ->
	    Rnew = new_uniq_id(),
	    {accept_resource, Rnew}
    end.

-spec bounce_message_queue() -> ok.
bounce_message_queue() ->
    receive {route, From, To, Pkt} ->
	    ejabberd_router:route(From, To, Pkt),
	    bounce_message_queue()
    after 0 ->
	    ok
    end.

-spec new_uniq_id() -> binary().
new_uniq_id() ->
    iolist_to_binary(
      [randoms:get_string(),
       integer_to_binary(p1_time_compat:unique_integer([positive]))]).

-spec get_conn_type(state()) -> c2s | c2s_tls | c2s_compressed | websocket |
				c2s_compressed_tls | http_bind.
get_conn_type(State) ->
    case xmpp_stream_in:get_transport(State) of
	tcp -> c2s;
	tls -> c2s_tls;
	tcp_zlib -> c2s_compressed;
	tls_zlib -> c2s_compressed_tls;
	http_bind -> http_bind;
	websocket -> websocket
    end.

-spec fix_from_to(xmpp_element(), state()) -> stanza().
fix_from_to(Pkt, #{jid := JID}) when ?is_stanza(Pkt) ->
    #jid{luser = U, lserver = S, lresource = R} = JID,
    From = xmpp:get_from(Pkt),
    From1 = case jid:tolower(From) of
		{U, S, R} -> JID;
		{U, S, _} -> jid:replace_resource(JID, From#jid.resource);
		_ -> From
	    end,
    xmpp:set_from_to(Pkt, From1, JID);
fix_from_to(Pkt, _State) ->
    Pkt.

-spec change_shaper(state()) -> ok.
change_shaper(#{shaper := ShaperName, ip := IP, lserver := LServer,
		user := U, server := S, resource := R} = State) ->
    JID = jid:make(U, S, R),
    Shaper = acl:access_matches(ShaperName,
				#{usr => jid:split(JID), ip => IP},
				LServer),
    xmpp_stream_in:change_shaper(State, Shaper).

-spec add_to_pres_a(state(), jid()) -> state().
add_to_pres_a(#{pres_a := PresA, pres_f := PresF} = State, From) ->
    LFrom = jid:tolower(From),
    LBFrom = jid:remove_resource(LFrom),
    case (?SETS):is_element(LFrom, PresA) orelse
	 (?SETS):is_element(LBFrom, PresA) of
	true ->
	    State;
	false ->
	    case (?SETS):is_element(LFrom, PresF) of
		true ->
		    A = (?SETS):add_element(LFrom, PresA),
		    State#{pres_a => A};
		false ->
		    case (?SETS):is_element(LBFrom, PresF) of
			true ->
			    A = (?SETS):add_element(LBFrom, PresA),
			    State#{pres_a => A};
			false ->
			    State
		    end
	    end
    end.

-spec format_reason(state(), term()) -> binary().
format_reason(#{stop_reason := Reason}, _) ->
    xmpp_stream_in:format_error(Reason);
format_reason(_, normal) ->
    <<"unknown reason">>;
format_reason(_, shutdown) ->
    <<"stopped by supervisor">>;
format_reason(_, {shutdown, _}) ->
    <<"stopped by supervisor">>;
format_reason(_, _) ->
    <<"internal server error">>.

transform_listen_option(Opt, Opts) ->
    [Opt|Opts].

opt_type(domain_certfile) -> fun iolist_to_binary/1;
opt_type(c2s_certfile) -> fun iolist_to_binary/1;
opt_type(c2s_ciphers) -> fun iolist_to_binary/1;
opt_type(c2s_dhfile) -> fun iolist_to_binary/1;
opt_type(c2s_cafile) -> fun iolist_to_binary/1;
opt_type(c2s_protocol_options) ->
    fun (Options) -> str:join(Options, <<"|">>) end;
opt_type(c2s_tls_compression) ->
    fun (true) -> true;
	(false) -> false
    end;
opt_type(resource_conflict) ->
    fun (setresource) -> setresource;
	(closeold) -> closeold;
	(closenew) -> closenew;
	(acceptnew) -> acceptnew
    end;
opt_type(disable_sasl_mechanisms) ->
    fun (V) when is_list(V) ->
	    lists:map(fun (M) -> str:to_upper(M) end, V);
	(V) -> [str:to_upper(V)]
    end;
opt_type(_) ->
    [domain_certfile, c2s_certfile, c2s_ciphers, c2s_cafile,
     c2s_protocol_options, c2s_tls_compression, resource_conflict,
     disable_sasl_mechanisms].
