// =====[ EVENTS ]=====

void OnPluginStart_Events()
{
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
	HookEvent("player_connect", Event_PlayerConnect, EventHookMode_Pre);
	HookEvent("player_connect_full", Event_PlayerConnectFull, EventHookMode_Pre);
	HookEvent("player_activate", Event_PlayerActivate, EventHookMode_Pre);
	AddCommandListener(CommandListener_Kick, "kickid");
	AddCommandListener(CommandListener_Kick, "kickid_ex");
	AddCommandListener(CommandListener_Kick, "kick");
}

// Blocking in pre also hides it from logic_eventlistener
public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client == 0)
	{
		return Plugin_Continue;
	}

	// The engine's bot reports "BOT"
	if (OwnsHeldUserID(client))
	{
		char networkID[32];
		GetHeldNetworkID(client, networkID, sizeof(networkID));
		event.SetString("networkid", networkID);
		char steamID64[24];
		GetHeldSteamID64(client, steamID64, sizeof(steamID64));
		event.SetString("xuid", steamID64);
	}

	char reason[128], playerName[MAX_NAME_LENGTH];
	event.GetString("reason", reason, sizeof(reason));
	event.GetString("name", playerName, sizeof(playerName));
	return OnPlayerDisconnect_Hold(client, reason, playerName);
}

// Fired inside ConnectClient
public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast)
{
	int routed = GetRoutedClient();
	int index = event.GetInt("index");
	return routed != 0 && index == routed - 1 || IsMakingBot(index + 1) ? Plugin_Handled : Plugin_Continue;
}

public Action Event_PlayerConnectFull(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client == 0)
	{
		return Plugin_Continue;
	}

	OnClientFullyConnected_Away(client);
	if (!ConsumeBlockedEvent(client, BlockedEvent_ConnectFull))
	{
		return Plugin_Continue;
	}

	OnRejoinFullyConnected(client);
	return Plugin_Handled;
}

public Action Event_PlayerActivate(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	return client != 0 && (IsMakingBot(client) || ConsumeBlockedEvent(client, BlockedEvent_Activate)) ? Plugin_Handled : Plugin_Continue;
}

// Engine kicks miss held slots; SourceMod's show in IsClientInKickQueue
public Action CommandListener_Kick(int client, const char[] command, int argc)
{
	char args[256];
	GetCmdArgString(args, sizeof(args));
	TrimString(args);
	// Quoted, the target is the first argument; unquoted, the tokenizer splits a SteamID at its colons
	if (args[0] == '"')
	{
		GetCmdArg(1, args, sizeof(args));
	}
	int target = FindKickTarget(args, StrEqual(command, "kick"));
	if (target != 0)
	{
		OnKickCommand(target);
	}
	return Plugin_Continue;
}
