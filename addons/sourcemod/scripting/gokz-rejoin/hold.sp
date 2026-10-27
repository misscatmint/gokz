enum struct HeldSlot
{
	int accountID;
	int userID;
	float deadline;
	char name[MAX_NAME_LENGTH];
	char networkID[32]; // SteamID as the engine prints it
	char steamID64[24];
	int holdMinutes;
	float timeAtHold;
	bool verified; // by Steam, so the run may save under accountID
}

// Leaving or losing the connection; kicks, bans and refused auth are never held
static const char leaveReasons[][] =
{
	"Disconnect",
	"Disconnect by user",
	"Disconnected by user",
	"Connection closing",
	"Connection lost",
	"No user logon", // Steam cancelled the ticket, as when the game closes
	"#GameUI_Disconnect_User",
	"#GameUI_Disconnect_DisconnectByUser",
	"#GameUI_Disconnect_ConnectionClosing"
};

enum
{
	BlockedEvent_ConnectFull = 1 << 0,
	BlockedEvent_Activate = 1 << 1
}

static HeldSlot heldSlot[MAXPLAYERS + 1];
static bool held[MAXPLAYERS + 1];
static bool rejoining[MAXPLAYERS + 1];
static bool restoreAngles[MAXPLAYERS + 1];
static float heldAngles[MAXPLAYERS + 1][3];
static int blockedEvents[MAXPLAYERS + 1];
static bool endHoldOnRemove[MAXPLAYERS + 1];
static bool engineBot[MAXPLAYERS + 1];
static int unbotting;
static float nextPauseAttempt[MAXPLAYERS + 1];
static int lastCmdNum[MAXPLAYERS + 1];
static float timeAtLastInput[MAXPLAYERS + 1]; // timer time at the player's last own command
static int releasingClient;
static bool handingOver[MAXPLAYERS + 1]; // what gokz-core reports as a carried-over run
static int savedHibernateWhenEmpty = -1;
static bool settingHibernation;
static bool adminSetHibernation;
static ConVar cvHibernateWhenEmpty;



// =====[ PUBLIC ]=====

bool IsHeld(int client)
{
	return held[client];
}

bool IsEngineBot(int client)
{
	return engineBot[client];
}

bool IsRejoining(int client)
{
	return client >= 1 && client <= MaxClients && rejoining[client];
}

int GetHeldUserID(int client)
{
	return heldSlot[client].userID;
}

bool IsHeldVerified(int client)
{
	return heldSlot[client].verified;
}

int GetHeldAccountID(int client)
{
	return heldSlot[client].accountID;
}

void GetHeldSteamID64(int client, char[] buffer, int maxlength)
{
	strcopy(buffer, maxlength, heldSlot[client].steamID64);
}

void GetHeldNetworkID(int client, char[] buffer, int maxlength)
{
	strcopy(buffer, maxlength, heldSlot[client].networkID);
}

bool IsHeldUserID(int userID)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client] && heldSlot[client].userID == userID)
		{
			return true;
		}
	}
	return false;
}

int FindHeldClient(int accountID)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client] && !rejoining[client] && heldSlot[client].accountID == accountID)
		{
			return client;
		}
	}
	return 0;
}

bool ConsumeBlockedEvent(int client, int event)
{
	if (blockedEvents[client] & event)
	{
		blockedEvents[client] &= ~event;
		return true;
	}
	return false;
}

// force also releases a rejoin in progress
void Release(int client, const char[] reason = "Disconnect", bool force = false)
{
	if (!held[client] || rejoining[client] && !force)
	{
		return;
	}

	bool wasEngineBot = engineBot[client];
	NoteHoldEnded(client, reason);
	Call_OnHoldEnd(client);
	EndHold(client);
	releasingClient = client;
	PublishHold(client);
	LogMessage("Released held slot of \"%s\" <%s>", heldSlot[client].name, heldSlot[client].networkID);

	// Its player_disconnect and RemoveClientFromGame then run as for any bot
	if (wasEngineBot)
	{
		DisconnectEngineClient(client, reason);
		releasingClient = 0;
		PublishHold(client);
		UpdateHibernation();
		return;
	}

	// The player_disconnect blocked at hold start
	Event event = CreateEvent("player_disconnect", true);
	event.SetInt("userid", heldSlot[client].userID);
	event.SetString("reason", reason);
	event.SetString("name", heldSlot[client].name);
	event.SetString("networkid", heldSlot[client].networkID);
	event.SetString("xuid", heldSlot[client].steamID64);
	event.Fire();

	DeliverDisconnect(client);
	releasingClient = 0;
	PublishHold(client);
	UpdateHibernation();
}

bool OwnsHeldUserID(int client)
{
	return held[client] || client == releasingClient;
}

void ReleaseExpiredHolds()
{
	char reason[64];
	float now = GetEngineTime();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!held[client])
		{
			continue;
		}
		if (IsClientInKickQueue(client))
		{
			Release(client, "Kicked");
		}
		else if (!EngineCanHold() || gCV_gokz_rejoin_hold_time.FloatValue <= 0.0)
		{
			Release(client, "Run hold disabled");
		}
		else if (!rejoining[client] && now >= heldSlot[client].deadline)
		{
			FormatEx(reason, sizeof(reason), "Run hold expired after %d min", heldSlot[client].holdMinutes);
			Release(client, reason);
		}
	}
}

// Once gokz's pause rules allow it, unless another plugin refuses
void PauseHeldPlayers()
{
	float now = GetEngineTime();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client] && !rejoining[client] && now >= nextPauseAttempt[client]
			 && !GOKZ_GetPaused(client) && GOKZ_GetCanPause(client))
		{
			nextPauseAttempt[client] = now + 1.0;
			GOKZ_Pause(client);
		}
	}
}

// Its engine bot, so releasing it frees the slot at once
int FindShortestHeldRun()
{
	int shortest = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client] && engineBot[client] && !rejoining[client]
			 && (shortest == 0 || GOKZ_GetTime(client) < GOKZ_GetTime(shortest)))
		{
			shortest = client;
		}
	}
	return shortest;
}

void ReleaseForSlot(int client)
{
	Release(client, "Server full");
}

void ReleaseAllHolds()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		// Its disconnect takes the kicked-rejoin path in OnEngineRemovesClient, which ends the hold
		if (rejoining[client])
		{
			DisconnectEngineClient(client, "Plugin unloaded");
		}
		Release(client, "Plugin unloaded", true);
	}
	// No frame follows an unload
	RestoreHibernation();
}

// SourceMod already disconnected everyone. Players' entities are freed later by InactivateClients
// through RemoveClientFromGame, and a held engine bot's edict pointer is only cleared by CGameClient::Clear
void DropAllHolds()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client])
		{
			LogMessage("Map change ended the hold on \"%s\" <%s>", heldSlot[client].name, heldSlot[client].networkID);
			NoteHoldEnded(client, "Map changed");
			Call_OnHoldEnd(client);
			EndHold(client);
		}
	}
	UpdateHibernation();
}



// =====[ EVENTS ]=====

void OnPluginStart_Hold()
{
	cvHibernateWhenEmpty = FindConVar("sv_hibernate_when_empty");
	if (cvHibernateWhenEmpty == null)
	{
		SetFailState("Could not find sv_hibernate_when_empty");
	}
	cvHibernateWhenEmpty.AddChangeHook(OnHibernateWhenEmptyChanged);
}

public void OnHibernateWhenEmptyChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!settingHibernation && savedHibernateWhenEmpty != -1)
	{
		adminSetHibernation = true;
	}
}

Action OnPlayerDisconnect_Hold(int client, const char[] reason, const char[] playerName)
{
	if (client == releasingClient)
	{
		return Plugin_Continue;
	}
	if (client == unbotting)
	{
		return Plugin_Handled;
	}
	// The recycled slot, already held by the same address reconnect in OnEngineRemovesClient
	if (InSameAddressReconnect() && client == GetRoutedClient())
	{
		return Plugin_Handled;
	}
	// Kicked from outside: the engine removes its bot and the hold ends
	if (held[client] && engineBot[client])
	{
		endHoldOnRemove[client] = true;
		return Plugin_Continue;
	}

	restoreAngles[client] = false;
	bool leaving = IsLeaveReason(reason, playerName);

	if (rejoining[client])
	{
		// Refused by the deferred ClientConnect; RemoveClientFromGame ends the hold
		if (IsRunningDeferredConnect(client))
		{
			return Plugin_Continue;
		}

		// A kick or ban of the loading client ends the hold; RemoveClientFromGame finishes it
		if (!leaving)
		{
			endHoldOnRemove[client] = true;
			return Plugin_Continue;
		}

		// Dropped before the rejoin finished, so back to a plain hold. A connection that died while
		// loading gets here only once the engine times it out, up to 300 s later, and until then its
		// Steam session refuses the account's retries, as the fake flag keeps the same-address
		// recycle off this slot
		rejoining[client] = false;
		handingOver[client] = false;
		PublishHold(client);
		blockedEvents[client] = 0;
		UnhookRejoinConnection(client);
		return Plugin_Handled;
	}

	blockedEvents[client] = 0;
	if (!leaving)
	{
		return Plugin_Continue;
	}

	char refusal[64];
	GetHoldRefusal(client, refusal, sizeof(refusal));
	if (refusal[0] != '\0')
	{
		// Only for runs, else every disconnect would log
		if (IsValidClient(client) && GOKZ_GetTimerRunning(client))
		{
			LogMessage("Not holding the run of \"%s\": %s", playerName, refusal);
		}
		return Plugin_Continue;
	}

	StartHold(client);
	if (AnnounceConnections())
	{
		GOKZ_PrintToChatAll(false, "%t", "Held Disconnection Message", client, reason, heldSlot[client].holdMinutes);
	}
	return Plugin_Handled;
}

// Returns whether to skip RemoveClientFromGame
bool OnEngineRemovesClient(int client)
{
	if (client == unbotting)
	{
		return true;
	}

	if (endHoldOnRemove[client] && engineBot[client])
	{
		LogMessage("Held slot of \"%s\" <%s> was kicked", heldSlot[client].name, heldSlot[client].networkID);
		NoteHoldEnded(client, "Kicked");
		Call_OnHoldEnd(client);
		EndHold(client);
		UpdateHibernation();
		return false;
	}

	if (endHoldOnRemove[client])
	{
		LogMessage("Rejoin of \"%s\" <%s> was dropped, releasing their held slot", heldSlot[client].name, heldSlot[client].networkID);
		Call_OnHoldEnd(client);
		EndHold(client);
		releasingClient = client;
		PublishHold(client);
		DeliverDisconnect(client);
		releasingClient = 0;
		PublishHold(client);
		UpdateHibernation();
		return true;
	}

	// Refused rejoin: SourceMod already dropped the old connection
	if (held[client] && IsRunningDeferredConnect(client))
	{
		LogMessage("Rejoin of \"%s\" <%s> was rejected, releasing their held slot", heldSlot[client].name, heldSlot[client].networkID);
		Call_OnHoldEnd(client);
		EndHold(client);
		UpdateHibernation();
		return false;
	}

	// At hold start, or after a rejoin dropped; the engine is still disconnecting this client
	if (held[client])
	{
		ApplyHold(client);
		BlockTransmit(client);
		RequestFrame(Frame_BecomeBot, client);
		return true;
	}

	// Same address reconnect: the engine recycles the slot, and its player_disconnect is blocked
	if (InSameAddressReconnect() && CanHold(client)
		 && GetConnectingAccountID() != 0 && GetSteamAccountID(client, false) == GetConnectingAccountID())
	{
		StartHold(client);
		ApplyHold(client);
		BlockTransmit(client);
		RouteRejoin(client);
		return true;
	}

	blockedEvents[client] = 0;
	return false;
}

// Refused after routing (ticket, ban, ...): the bot was already stopped
void OnRejoinRefused(int client)
{
	RequestFrame(Frame_BecomeBot, client);
}

void OnRejoinRouted(int client)
{
	rejoining[client] = true;
	blockedEvents[client] = BlockedEvent_ConnectFull | BlockedEvent_Activate;
	HookRejoinConnection(client);
}

public void Frame_BecomeBot(int client)
{
	if (!held[client] || rejoining[client] || engineBot[client])
	{
		return;
	}

	handingOver[client] = true;
	PublishHold(client);
	MakeEngineBot(client, heldSlot[client].name, heldSlot[client].userID);
	handingOver[client] = false;
	PublishHold(client);
	engineBot[client] = true;
	SDKUnhook(client, SDKHook_SetTransmit, Hook_HeldSetTransmit);
	CS_SetClientClanTag(client, "[DISCONNECTED]");
}

// The rejoin needs the slot cleared, as at hold start
void StopEngineBot(int client)
{
	if (!engineBot[client])
	{
		return;
	}

	unbotting = client;
	DisconnectEngineClient(client, "Rejoining");
	unbotting = 0;
	engineBot[client] = false;
	ApplyHold(client);
	BlockTransmit(client);
}

// SourceMod dropped the hook; the new connection is inactive until ClientActive
void OnClientPutInServer_Hold(int client)
{
	// Command numbers restart with each connection
	lastCmdNum[client] = 0;
	if (IsRejoining(client))
	{
		BlockTransmit(client);
	}
}

// SourceMod's disconnect of the old connection
void OnClientDisconnect_Hold(int client)
{
	if (rejoining[client])
	{
		GetClientEyeAngles(client, heldAngles[client]);
	}
}

// The deferred ClientConnect, where SourceMod drops the bot and connects the rejoin. The handover lasts until ClientActive
void OnDeferredConnect(int client)
{
	handingOver[client] = true;
	PublishHold(client);
}

void OnRejoinActive(int client)
{
	held[client] = false;
	rejoining[client] = false;
	handingOver[client] = false;
	PublishHold(client);
	SDKUnhook(client, SDKHook_SetTransmit, Hook_HeldSetTransmit);
	UnhookRejoinConnection(client);
	UpdateHibernation();
	if (LibraryExists("gokz-jumpstats"))
	{
		GOKZ_JS_InvalidateJump(client);
	}

	LogMessage("\"%s\" <%s> rejoined their held slot", heldSlot[client].name, heldSlot[client].networkID);
	if (AnnounceConnections())
	{
		GOKZ_PrintToChatAll(false, "%t", "Rejoin Message", client);
	}
	Call_OnRejoin(client);
}

// First point chat reaches the rejoined client
void OnRejoinFullyConnected(int client)
{
	restoreAngles[client] = true;
}

bool OnPlayerRunCmd_Hold(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int cmdnum, int mouse[2])
{
	// Commands queued in the hold's first frame run after ReleaseInputs and rewrite m_LastCmd, which the replay repeats
	if (held[client])
	{
		buttons = 0;
		impulse = 0;
		vel[0] = 0.0;
		vel[1] = 0.0;
		vel[2] = 0.0;
		weapon = 0;
		subtype = 0;
		mouse[0] = 0;
		mouse[1] = 0;
		ClearLastCmdInputs(client);
		return true;
	}

	// A replayed command keeps its number
	if (cmdnum != lastCmdNum[client])
	{
		lastCmdNum[client] = cmdnum;
		timeAtLastInput[client] = GOKZ_GetTime(client);
	}

	// The new client starts with its own view angles
	if (!restoreAngles[client])
	{
		return false;
	}

	restoreAngles[client] = false;
	angles = heldAngles[client];
	TeleportEntity(client, NULL_VECTOR, angles, NULL_VECTOR);

	// The run may have ended while they were loading
	if (!GOKZ_GetTimerRunning(client))
	{
		ShowAwayNote(client);
		return true;
	}
	if (GOKZ_GetPaused(client))
	{
		GOKZ_PrintToChat(client, true, "%t", "Rejoined Held Slot (Paused)");
	}
	else
	{
		GOKZ_PrintToChat(client, true, "%t", "Rejoined Held Slot", GOKZ_FormatTime(GOKZ_GetTime(client) - heldSlot[client].timeAtHold));
	}
	// The resumed timer never starts again, so gokz-localdb's warning at the start never shows
	if (GetSteamAccountID(client) == 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "Rejoined Held Slot (Unverified)");
	}
	return true;
}

void OnTimerStopped_Hold(int client)
{
	if (held[client])
	{
		RequestFrame(Frame_Release, GetClientUserId(client));
	}
}



// =====[ PRIVATE ]=====

// gokz-chat's gokz_connection_messages
static bool AnnounceConnections()
{
	// gokz-chat's, which may load after this plugin
	static ConVar connectionMessages;
	if (connectionMessages == null)
	{
		connectionMessages = FindConVar("gokz_connection_messages");
	}
	return connectionMessages == null || connectionMessages.BoolValue;
}

static bool IsLeaveReason(const char[] reason, const char[] playerName)
{
	for (int i = 0; i < sizeof(leaveReasons); i++)
	{
		if (StrEqual(reason, leaveReasons[i], false))
		{
			return true;
		}
	}
	// Exactly "<name> timed out", also a crash; a kick message can end the same way
	char timedOut[MAX_NAME_LENGTH + 16];
	FormatEx(timedOut, sizeof(timedOut), "%s timed out", playerName);
	return StrEqual(reason, timedOut);
}

static bool CanHold(int client)
{
	char refusal[64];
	GetHoldRefusal(client, refusal, sizeof(refusal));
	return refusal[0] == '\0';
}

// The first reason a player cannot be held, or "" if they can
static void GetHoldRefusal(int client, char[] buffer, int maxlength)
{
	buffer[0] = '\0';
	if (gCV_gokz_rejoin_hold_time.FloatValue <= 0.0)
	{
		strcopy(buffer, maxlength, "gokz_rejoin_hold_time is 0");
	}
	else if (!IsValidClient(client) || IsFakeClient(client))
	{
		strcopy(buffer, maxlength, "not a player");
	}
	else if (GetSteamAccountID(client, false) == 0)
	{
		strcopy(buffer, maxlength, "no Steam account ID");
	}
	else if (!IsPlayerAlive(client))
	{
		strcopy(buffer, maxlength, "not alive");
	}
	else if (!GOKZ_GetTimerRunning(client))
	{
		strcopy(buffer, maxlength, "timer not running");
	}
	else if (IsClientInKickQueue(client))
	{
		strcopy(buffer, maxlength, "being kicked");
	}
	else if (!EngineCanHold())
	{
		strcopy(buffer, maxlength, "sv_maxusrcmdprocessticks is 0");
	}
}

static void StartHold(int client)
{
	// The engine checked the ticket at connect; Steam's verdict may still be pending
	heldSlot[client].accountID = GetSteamAccountID(client, false);
	heldSlot[client].userID = GetClientUserId(client);
	heldSlot[client].deadline = GetEngineTime() + gCV_gokz_rejoin_hold_time.FloatValue;
	heldSlot[client].holdMinutes = RoundToCeil(gCV_gokz_rejoin_hold_time.FloatValue / 60.0);
	// The body replayed that command until now, a crashed connection's for its whole timeout
	heldSlot[client].timeAtHold = timeAtLastInput[client];
	heldSlot[client].verified = IsClientAuthorized(client);
	GetClientAuthId(client, AuthId_SteamID64, heldSlot[client].steamID64, sizeof(HeldSlot::steamID64), false);
	GetClientName(client, heldSlot[client].name, sizeof(HeldSlot::name));
	GetClientAuthId(client, AuthId_Engine, heldSlot[client].networkID, sizeof(HeldSlot::networkID), false);
	held[client] = true;
	PublishHold(client);
	blockedEvents[client] = 0;
	UpdateHibernation();
	OnHoldStart_Away(client);

	// The rest of the flight has no player input
	if (LibraryExists("gokz-jumpstats"))
	{
		GOKZ_JS_InvalidateJump(client);
	}

	LogMessage("Holding slot of \"%s\" <%s> for %.0f seconds", heldSlot[client].name, heldSlot[client].networkID, gCV_gokz_rejoin_hold_time.FloatValue);
	Call_OnHoldStart(client);
}

static void EndHold(int client)
{
	held[client] = false;
	rejoining[client] = false;
	handingOver[client] = false;
	restoreAngles[client] = false;
	blockedEvents[client] = 0;
	endHoldOnRemove[client] = false;
	engineBot[client] = false;
	UnhookRejoinConnection(client);
	PublishHold(client);
}

// gokz-core keeps what other plugins read about held runs
static void PublishHold(int client)
{
	GOKZ_SetRunHeld(client, OwnsHeldUserID(client), IsHeldVerified(client) ? GetHeldAccountID(client) : 0);
	GOKZ_SetRunCarriedOver(client, handingOver[client]);
}

static void ApplyHold(int client)
{
	ReleaseInputs(client);
}

// While the slot is inactive: weapons force their parent into transmit lists, and the engine aborts on it
static void BlockTransmit(int client)
{
	SDKUnhook(client, SDKHook_SetTransmit, Hook_HeldSetTransmit);
	SDKHook(client, SDKHook_SetTransmit, Hook_HeldSetTransmit);
}

public Action Hook_HeldSetTransmit(int entity, int client)
{
	return Plugin_Handled;
}

static bool AnyHeld()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client])
		{
			return true;
		}
	}
	return false;
}

// Hibernation would freeze the world, a free pause
static void UpdateHibernation()
{
	if (AnyHeld() && savedHibernateWhenEmpty == -1)
	{
		savedHibernateWhenEmpty = cvHibernateWhenEmpty.IntValue;
		settingHibernation = true;
		cvHibernateWhenEmpty.IntValue = 0;
		settingHibernation = false;
	}
	else if (!AnyHeld() && savedHibernateWhenEmpty != -1)
	{
		// The write runs the engine's hibernation check at once, which inside the last held bot's disconnect would disconnect it a second time
		RequestFrame(Frame_RestoreHibernation);
	}
}

public void Frame_RestoreHibernation(any data)
{
	RestoreHibernation();
}

static void RestoreHibernation()
{
	if (AnyHeld() || savedHibernateWhenEmpty == -1)
	{
		return;
	}

	// Unless an admin set it meanwhile
	if (!adminSetHibernation)
	{
		settingHibernation = true;
		cvHibernateWhenEmpty.IntValue = savedHibernateWhenEmpty;
		settingHibernation = false;
	}
	savedHibernateWhenEmpty = -1;
	adminSetHibernation = false;
}

public void Frame_Release(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !held[client])
	{
		return;
	}

	// A rejoin in progress still finishes, and the note tells the player
	if (rejoining[client])
	{
		NoteHoldEnded(client, "Timer stopped");
		return;
	}
	Release(client, IsHeldRunFinished(client) ? "Run finished" : "Timer stopped");
}
