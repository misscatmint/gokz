#define STEAM_LOGON_REJECTED "No user logon"

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
	bool pausedAtHold;
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
	STEAM_LOGON_REJECTED, // Steam cancelled the ticket, as when the game closes
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
static bool rejoined[MAXPLAYERS + 1];
static bool restoreAngles[MAXPLAYERS + 1];
static float heldAngles[MAXPLAYERS + 1][3];
static int blockedEvents[MAXPLAYERS + 1];
static char removalReason[MAXPLAYERS + 1][128];
static bool endHoldOnRemove[MAXPLAYERS + 1];
static bool kicked[MAXPLAYERS + 1];
static bool engineBot[MAXPLAYERS + 1];
static int unbotting;
static float nextPauseAttempt[MAXPLAYERS + 1];
static int releasingClient;
static int handingOver;
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

// Also while the slot is handed to SourceMod as a bot
bool IsRejoin(int client)
{
	return rejoined[client] || client == handingOver;
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

int GetHoldMinutes(int client)
{
	return heldSlot[client].holdMinutes;
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

// kickid takes a userid or SteamID first, kick a name or #userid
int FindKickTarget(const char[] args, bool byName)
{
	if (args[0] == '#' || !byName && IsCharNumeric(args[0]))
	{
		return GetClientOfUserId(StringToInt(args[args[0] == '#' ? 1 : 0]));
	}

	char networkID[32], playerName[MAX_NAME_LENGTH];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client])
		{
			strcopy(networkID, sizeof(networkID), heldSlot[client].networkID);
			strcopy(playerName, sizeof(playerName), heldSlot[client].name);
		}
		else if (!IsClientConnected(client) || IsFakeClient(client)
			 || !GetClientAuthId(client, AuthId_Engine, networkID, sizeof(networkID), false)
			 || !GetClientName(client, playerName, sizeof(playerName)))
		{
			continue;
		}

		int length = strlen(networkID);
		if (length > 0 && strncmp(args, networkID, length, false) == 0 && (args[length] == '\0' || args[length] == ' ')
			 || byName && StrEqual(args, playerName))
		{
			return client;
		}
	}
	return 0;
}

// Its disconnect is then not a leave, even with a leave-like message
void OnKickCommand(int client)
{
	kicked[client] = true;
	if (held[client])
	{
		Release(client, "Kicked");
	}
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
	Call_OnHoldEnd(client);
	EndHold(client);
	releasingClient = client;
	PublishHold(client);
	LogMessage("Released held slot of \"%s\" <%s>", heldSlot[client].name, heldSlot[client].networkID);
	AnnounceHoldEnd(client, reason);

	// Its player_disconnect and RemoveClientFromGame then run as for any bot
	if (wasEngineBot)
	{
		DisconnectEngineBot(client, reason);
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
			NoteHoldEnded(client, AwayRunEnd_Timeout);
			Release(client, "Run hold expired");
		}
	}
}

// Once gokz's pause rules allow it; another plugin may refuse, as gokz-racing does
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
int FindOldestHold()
{
	int oldest = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client] && engineBot[client] && !rejoining[client]
			 && (oldest == 0 || heldSlot[client].deadline < heldSlot[oldest].deadline))
		{
			oldest = client;
		}
	}
	return oldest;
}

void ReleaseForSlot(int client)
{
	NoteHoldEnded(client, AwayRunEnd_ServerFull);
	Release(client, "Server full");
}

void ReleaseAllHolds()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		// The new connection never got ClientConnect; dropping it leaves a plain hold
		if (rejoining[client])
		{
			InsertServerCommand("kickid %d", heldSlot[client].userID);
			ServerExecute();
		}
		Release(client, _, true);
		// gokz-core would otherwise still report a rejoin after this plugin unloads
		if (rejoined[client])
		{
			rejoined[client] = false;
			PublishHold(client);
		}
	}
}

// SourceMod already disconnected everyone; level shutdown frees the entity
void DropAllHolds()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (held[client])
		{
			LogMessage("Map change ended the hold on \"%s\" <%s>", heldSlot[client].name, heldSlot[client].networkID);
			NoteHoldEnded(client, AwayRunEnd_MapChange);
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
	// RemoveClientFromGame gets no reason
	strcopy(removalReason[client], sizeof(removalReason[]), reason);
	// Kicked from outside: the engine removes its bot and the hold ends
	if (held[client] && engineBot[client])
	{
		endHoldOnRemove[client] = true;
		return Plugin_Continue;
	}

	restoreAngles[client] = false;
	bool leaving = !kicked[client] && IsLeaveReason(reason, playerName);
	kicked[client] = false;

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

		// Dropped before the rejoin finished, so back to a plain hold
		rejoining[client] = false;
		rejoined[client] = false;
		PublishHold(client);
		blockedEvents[client] = 0;
		UnhookRejoinConnection(client);
		return Plugin_Handled;
	}

	// Steam rejected a rejoin it had not yet vouched for: not the owner, so no new hold
	if (rejoined[client] && !IsClientAuthorized(client) && StrEqual(reason, STEAM_LOGON_REJECTED))
	{
		leaving = false;
	}

	rejoined[client] = false;
	PublishHold(client);
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
		AnnounceHoldEnd(client, removalReason[client]);
		Call_OnHoldEnd(client);
		EndHold(client);
		UpdateHibernation();
		return false;
	}

	if (endHoldOnRemove[client])
	{
		LogMessage("Rejoin of \"%s\" <%s> was kicked, releasing their held slot", heldSlot[client].name, heldSlot[client].networkID);
		AnnounceHoldEnd(client, removalReason[client]);
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
		AnnounceHoldEnd(client, removalReason[client]);
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

	// Same address reconnect: no player_disconnect, the slot is reused
	if (InSameAddressReconnect() && CanHold(client)
		 && GetConnectingAccountID() != 0 && GetSteamAccountID(client, false) == GetConnectingAccountID())
	{
		StartHold(client);
		ApplyHold(client);
		BlockTransmit(client);
		RouteRejoin(client);
		return true;
	}

	rejoined[client] = false;
	PublishHold(client);
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
	rejoined[client] = true;
	PublishHold(client);
	blockedEvents[client] = BlockedEvent_ConnectFull | BlockedEvent_Activate;
	HookRejoinConnection(client);
}

public void Frame_BecomeBot(int client)
{
	if (!held[client] || rejoining[client] || engineBot[client])
	{
		return;
	}

	handingOver = client;
	PublishHold(client);
	MakeEngineBot(client, heldSlot[client].name, heldSlot[client].userID);
	handingOver = 0;
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
	DisconnectEngineBot(client, "Rejoining");
	unbotting = 0;
	engineBot[client] = false;
	ApplyHold(client);
	BlockTransmit(client);
}

// SourceMod dropped the hook; the new connection is inactive until ClientActive
void OnClientPutInServer_Hold(int client)
{
	if (IsRejoining(client))
	{
		BlockTransmit(client);
	}
}

// SourceMod's disconnect of the old connection
void OnClientDisconnect_Hold(int client)
{
	kicked[client] = false;
	if (rejoining[client])
	{
		GetClientEyeAngles(client, heldAngles[client]);
	}
}

void OnRejoinActive(int client)
{
	held[client] = false;
	rejoining[client] = false;
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

// The new client starts with its own view angles
bool OnPlayerRunCmd_Hold(int client, float angles[3])
{
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
	// A paused timer stops, so this is how long it ran before pausing
	float ranFor = GOKZ_GetTime(client) - heldSlot[client].timeAtHold;
	bool paused = GOKZ_GetPaused(client);
	if (ranFor < 0.1)
	{
		GOKZ_PrintToChat(client, true, "%t", !paused ? "Rejoined Held Slot" : heldSlot[client].pausedAtHold ? "Rejoined Held Slot (Still Paused)" : "Rejoined Held Slot (Paused)");
	}
	else
	{
		GOKZ_PrintToChat(client, true, "%t", paused ? "Rejoined Held Slot (Paused, Ran)" : "Rejoined Held Slot (Ran)", GOKZ_FormatTime(ranFor));
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

static void AnnounceHoldEnd(int client, const char[] reason)
{
	if (AnnounceConnections())
	{
		GOKZ_PrintToChatAll(false, "%t", "Held Run Released", heldSlot[client].name, reason);
	}
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
	else if (!SteamChecksTickets())
	{
		strcopy(buffer, maxlength, "sv_lan 1");
	}
}

static void StartHold(int client)
{
	// The engine checked the ticket at connect; Steam's verdict may still be pending
	heldSlot[client].accountID = GetSteamAccountID(client, false);
	heldSlot[client].userID = GetClientUserId(client);
	heldSlot[client].deadline = GetEngineTime() + gCV_gokz_rejoin_hold_time.FloatValue;
	heldSlot[client].holdMinutes = RoundToCeil(gCV_gokz_rejoin_hold_time.FloatValue / 60.0);
	heldSlot[client].timeAtHold = GOKZ_GetTime(client);
	heldSlot[client].pausedAtHold = GOKZ_GetPaused(client);
	heldSlot[client].verified = IsClientAuthorized(client);
	GetClientAuthId(client, AuthId_SteamID64, heldSlot[client].steamID64, sizeof(HeldSlot::steamID64), false);
	GetClientName(client, heldSlot[client].name, sizeof(HeldSlot::name));
	GetClientAuthId(client, AuthId_Engine, heldSlot[client].networkID, sizeof(HeldSlot::networkID), false);
	held[client] = true;
	rejoined[client] = false;
	PublishHold(client);
	blockedEvents[client] = 0;
	UpdateHibernation();

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
	rejoined[client] = false;
	restoreAngles[client] = false;
	blockedEvents[client] = 0;
	endHoldOnRemove[client] = false;
	kicked[client] = false;
	engineBot[client] = false;
	UnhookRejoinConnection(client);
	PublishHold(client);
}

// gokz-core keeps what other plugins read about held runs
static void PublishHold(int client)
{
	GOKZ_SetRunHeld(client, OwnsHeldUserID(client), IsHeldVerified(client) ? GetHeldAccountID(client) : 0);
	GOKZ_SetRunCarriedOver(client, IsRejoin(client));
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

// Hibernation would freeze the world, a free pause
static void UpdateHibernation()
{
	bool anyHeld = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		anyHeld = anyHeld || held[client];
	}

	if (anyHeld && savedHibernateWhenEmpty == -1)
	{
		savedHibernateWhenEmpty = cvHibernateWhenEmpty.IntValue;
		settingHibernation = true;
		cvHibernateWhenEmpty.IntValue = 0;
		settingHibernation = false;
	}
	else if (!anyHeld && savedHibernateWhenEmpty != -1)
	{
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
}

public void Frame_Release(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !held[client])
	{
		return;
	}

	NoteHeldRunEnd(client);
	// A rejoin in progress still finishes, and the note tells the player
	if (!rejoining[client])
	{
		Release(client, "Run ended");
	}
}
