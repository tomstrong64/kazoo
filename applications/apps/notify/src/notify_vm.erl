%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, James Aimonetti
%%% @doc
%%% Handle updating devices and emails about voicemails
%%% @end
%%% Created :  3 May 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(notify_vm).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("notify.hrl").
-include_lib("callflow/include/cf_amqp.hrl").

-define(SERVER, ?MODULE).
-define(DEFAULT_VM_TEMPLATE, <<"New Voicemail Message\n\nCaller ID: {caller_id_number}\nCaller Name: {caller_id_name}\n\nCalled To: {to_user}   (Originally dialed number)\nCalled On: {date_called}\n\n\nFor help or questions using your phone or voicemail, please contact support at (415) 886-7950 or email support@2600hz.com">>).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{}, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(timeout, _) ->
    start_amqp(),
    {noreply, ok};

handle_info({_, #amqp_msg{props=#'P_basic'{content_type= <<"application/json">>}, payload=Payload}}, State) ->
    logger:format_log(info, "NOTIFY_VM(~p): AMQP Recv ~s~n", [self(), Payload]),
    spawn(fun() ->
		  JObj = mochijson2:decode(Payload),
		  true = validate(JObj),
		  update_mwi(JObj),
		  send_vm_to_email(JObj)
	  end),
    {noreply, State};

handle_info(_Info, State) ->
    logger:format_log(info, "NOTIFY_VM(~p): Unhandled ~p~n", [self(), _Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_amqp() ->
    Q = amqp_util:new_queue(),
    amqp_util:bind_q_to_callevt(Q, ?NOTIFY_VOICEMAIL_NEW, other),
    amqp_util:basic_consume(Q).

validate(JObj) ->
    validate(JObj, wh_json:get_value(<<"Event-Name">>, JObj)).

validate(JObj, <<"new_voicemail">>) ->
    cf_api:new_voicemail_v(JObj);
validate(_, _) ->
    false.

update_mwi(_JObj) ->
    not_implemented_yet.

send_vm_to_email(JObj) ->
    {ok, VMBox} = couch_mgr:open_doc(wh_json:get_value(<<"Account-DB">>, JObj), wh_json:get_value(<<"Voicemail-Box">>, JObj)),
    {ok, UserJObj} = couch_mgr:open_doc(wh_json:get_value(<<"Account-DB">>, JObj), wh_json:get_value(<<"owner_id">>, VMBox)),
    case {wh_json:get_value(<<"email">>, UserJObj), whistle_util:is_true(wh_json:get_value(<<"vm_to_email_enabled">>, UserJObj))} of
	{undefined, _} ->
	    logger:format_log(info, "NOTIFY_VM(~p): No email found for user ~p~n", [self(), wh_json:get_value(<<"username">>, UserJObj)]);
	{_Email, false} ->
	    logger:format_log(info, "NOTIFY_VM(~p): Voicemail to email disabled for ~p~n", [self(), _Email]);
	{Email, true} ->
	    VMTemplate = case wh_json:get_value(<<"vm_to_email_template">>, UserJObj) of
			     undefined -> ?DEFAULT_VM_TEMPLATE;
			     Tmpl -> Tmpl
			 end,
				 
	    send_vm_to_email(Email, VMTemplate, JObj)
    end.

send_vm_to_email(To, Tmpl, JObj) ->
    Subject = <<"New voicemail received">>,
    Body = format_plaintext(JObj, Tmpl),

    DB = wh_json:get_value(<<"Account-DB">>, JObj),
    Doc = wh_json:get_value(<<"Voicemail-Box">>, JObj),
    AttachmentId = wh_json:get_value(<<"Voicemail-Name">>, JObj),

    From = <<"no_reply@", (whistle_util:to_binary(net_adm:localhost()))/binary>>,

    {ok, AttachmentBin} = couch_mgr:fetch_attachment(DB, Doc, AttachmentId),

    Email = {<<"multipart">>, <<"mixed">> %% Content Type / Sub Type
		 ,[ %% Headers
		    {<<"From">>, From},
		    {<<"To">>, To},
		    {<<"Subject">>, Subject}
		  ]
	     ,[] %% Parameters
	     ,[ %% Body
		{<<"text">>, <<"plain">>, [{<<"Content-Type">>, <<"text/plain">>}], [], Body} %% Content Type, Subtype, Headers, Parameters, Body
		,{<<"audio">>, <<"mpeg">>
		      ,[
			{<<"Content-Disposition">>, list_to_binary([<<"attachment; filename=\"">>, AttachmentId, "\""])}
			,{<<"Content-Type">>, list_to_binary([<<"audio/mpeg; name=\"">>, AttachmentId, "\""])}
		       ]
		  ,[], AttachmentBin
		 }
	      ]
	    },
    Encoded = mimemail:encode(Email),
    SmartHost = smtp_util:guess_FQDN(),
    gen_smtp_client:send({From, [To], Encoded}, [{relay, SmartHost}]
			 ,fun(X) -> logger:format_log(info, "NOTIFY_VM: Sending email to ~p via ~p resulted in ~p~n", [To, SmartHost, X]) end).

format_plaintext(JObj, Tmpl) ->
    CIDName = wh_json:get_value(<<"Caller-ID-Name">>, JObj),
    CIDNum = wh_json:get_value(<<"Caller-ID-Number">>, JObj),
    ToE164 = whistle_util:to_e164(wh_json:get_value(<<"To-User">>, JObj)),
    DateCalled = wh_json:get_value(<<"Voicemail-Timestamp">>, JObj),

    lists:foldr(fun({K, V}, Tmpl0) ->
			binary:replace(Tmpl0, K, V, [global])
		end, Tmpl, [{<<"{caller_id_number}">>, CIDNum}
			    ,{<<"{caller_id_name}">>, CIDName}
			    ,{<<"{to_user}">>, ToE164}
			    ,{<<"{date_called}">>, DateCalled}
			    ]).
%% Monday, March XX, 2010 at 05:12 pm
