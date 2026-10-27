#define STEAM_AUTH_PROTOCOL 3
#define STEAMID64_INDIVIDUAL_HIGH 0x01100001 // public universe, individual account, desktop instance

// ConnectClient arguments, as numbered in the gamedata
enum
{
	ConnectArg_AuthProtocol = 4,
	ConnectArg_Cookie = 7,
	ConnectArg_CookieLength = 8
}
#define SIGNONSTATE_SPAWN 5
#define CROSSPLAYPLATFORM_PC 1

static Address gameServer; // sv, from the first RemoveClientFromGame; nothing is held before that
static int offsetClients;
static int offsetClientCount;
static int offsetUserIDCounter;
static int offsetFakePlayer;
static int offsetLastCmd;
static int offsetCmdTicksRemaining;
static const char userCmdInputs[][] = { "forwardmove", "sidemove", "upmove", "buttons", "impulse", "weaponselect", "weaponsubtype", "mousedx", "mousedy" };
static const NumberType userCmdInputSizes[] = { NumberType_Int32, NumberType_Int32, NumberType_Int32, NumberType_Int32, NumberType_Int8, NumberType_Int32, NumberType_Int32, NumberType_Int16, NumberType_Int16 };
static int userCmdInputOffsets[sizeof(userCmdInputs)];
static Address serverGameClients;
static Address serverGameEnts;
static Handle clientDisconnectCall;
static Handle botConnectCall;
static Handle botDisconnectCall;
static Handle activatePlayerCall;
static Handle freeContainingEntityCall;
static Handle baseEntityToEdictCall;
static ConVar cvMaxUserCmdProcessTicks;
static ConVar cvLan;

static int offsetCheckConnectThis;
static DynamicHook checkConnectHook;
static DynamicHook signonStateHook;
static Handle checkConnectCall;

static bool inGetFreeClient;
static bool inConnectClient;
static bool sourceModOnly;
static int makingBot;
static int connectingAccountID;
static int routedClient;
static int checkConnectHookID[MAXPLAYERS + 1] = { INVALID_HOOK_ID, ... };
static int signonStateHookID[MAXPLAYERS + 1] = { INVALID_HOOK_ID, ... };
static bool connectDeferred[MAXPLAYERS + 1];
static int deferredConnectClient;
static int savedUserIDCounter = -1;
static ArrayList hooksToRemove;



// =====[ PUBLIC ]=====

bool EngineCanHold()
{
	return cvMaxUserCmdProcessTicks.IntValue > 0;
}

int GetConnectingAccountID()
{
	return connectingAccountID;
}

bool InSameAddressReconnect()
{
	return inGetFreeClient;
}

int GetRoutedClient()
{
	return routedClient;
}

bool IsRunningDeferredConnect(int client)
{
	return deferredConnectClient == client;
}

// Into the held slot, under the old userid; ConnectClient's post hook puts the counter back
void RouteRejoin(int client)
{
	routedClient = client;
	Address counterAddr = gameServer + view_as<Address>(offsetUserIDCounter);
	if (savedUserIDCounter == -1)
	{
		savedUserIDCounter = LoadFromAddress(counterAddr, NumberType_Int32);
	}
	// GetNextUserID returns counter + 1
	StoreToAddress(counterAddr, GetHeldUserID(client) - 1, NumberType_Int32, false);
}

// sv_lan skips Steam's ticket check, so a claimed SteamID would go unchecked
bool SteamChecksTickets()
{
	return !cvLan.BoolValue;
}

// The engine replays m_LastCmd while no commands arrive; cleared, the player idles
void ReleaseInputs(int client)
{
	Address player = GetEntityAddress(client);
	Address cmd = player + view_as<Address>(offsetLastCmd);
	for (int i = 0; i < sizeof(userCmdInputs); i++)
	{
		StoreToAddress(cmd + view_as<Address>(userCmdInputOffsets[i]), 0, userCmdInputSizes[i], false);
	}
	StoreToAddress(player + view_as<Address>(offsetCmdTicksRemaining), cvMaxUserCmdProcessTicks.IntValue, NumberType_Int32, false);
}

// Defers ClientConnect, where SourceMod drops the old connection, to signon SPAWN
void HookRejoinConnection(int client)
{
	Address baseClient = GetBaseClient(client);
	checkConnectHookID[client] = checkConnectHook.HookRaw(Hook_Pre, baseClient + view_as<Address>(offsetCheckConnectThis), DHooks_OnCheckConnect);
	signonStateHookID[client] = signonStateHook.HookRaw(Hook_Pre, baseClient, DHooks_OnProcessSignonState);
}

// Removing a hook inside its own callback crashes DHooks
void UnhookRejoinConnection(int client)
{
	if (checkConnectHookID[client] != INVALID_HOOK_ID)
	{
		hooksToRemove.Push(checkConnectHookID[client]);
		checkConnectHookID[client] = INVALID_HOOK_ID;
	}
	if (signonStateHookID[client] != INVALID_HOOK_ID)
	{
		hooksToRemove.Push(signonStateHookID[client]);
		signonStateHookID[client] = INVALID_HOOK_ID;
	}
	connectDeferred[client] = false;
}

void RemoveUnusedHooks()
{
	for (int i = 0; i < hooksToRemove.Length; i++)
	{
		DynamicHook.RemoveHook(hooksToRemove.Get(i));
	}
	hooksToRemove.Clear();
}

bool IsMakingBot(int client)
{
	return client == makingBot;
}

// The engine's own bot setup (CreateFakeClient) on the held slot, keeping its body: the engine
// sends an active client's entity again, and SourceMod sees the player leave and a bot join
void MakeEngineBot(int client, const char[] name, int userID)
{
	Address edict = SDKCall(baseEntityToEdictCall, serverGameEnts, GetEntityAddress(client));
	Address baseClient = GetBaseClient(client);
	makingBot = client;
	sourceModOnly = true;
	SDKCall(clientDisconnectCall, serverGameClients, edict);
	SDKCall(botConnectCall, baseClient + view_as<Address>(offsetCheckConnectThis), name, userID, Address_Null, true, CROSSPLAYPLATFORM_PC, Address_Null);
	SDKCall(activatePlayerCall, baseClient);
	sourceModOnly = false;
	makingBot = 0;
}

void DisconnectEngineBot(int client, const char[] reason)
{
	SDKCall(botDisconnectCall, GetBaseClient(client) + view_as<Address>(offsetCheckConnectThis), reason);
}

// Raw edict: SourceMod rejects the client index after ClientDisconnect
void DeliverDisconnect(int client)
{
	Address edict = SDKCall(baseEntityToEdictCall, serverGameEnts, GetEntityAddress(client));
	SDKCall(clientDisconnectCall, serverGameClients, edict);
	SDKCall(freeContainingEntityCall, serverGameEnts, edict);
}



// =====[ EVENTS ]=====

void OnPluginStart_Engine()
{
	cvMaxUserCmdProcessTicks = FindConVar("sv_maxusrcmdprocessticks");
	if (cvMaxUserCmdProcessTicks == null)
	{
		SetFailState("Could not find sv_maxusrcmdprocessticks");
	}
	cvLan = FindConVar("sv_lan");
	if (cvLan == null)
	{
		SetFailState("Could not find sv_lan");
	}

	GameData gameData = new GameData("gokz-rejoin.games");
	if (gameData == null)
	{
		SetFailState("Failed to load gokz-rejoin gamedata");
	}

	offsetClients = GetOffsetOrFail(gameData, "CBaseServer::m_Clients");
	offsetClientCount = GetOffsetOrFail(gameData, "CBaseServer::m_ClientCount");
	offsetUserIDCounter = GetOffsetOrFail(gameData, "CBaseServer::m_nUserid");
	offsetFakePlayer = GetOffsetOrFail(gameData, "CBaseClient::m_bFakePlayer");
	offsetLastCmd = GetOffsetOrFail(gameData, "CBasePlayer::m_LastCmd");
	offsetCmdTicksRemaining = GetOffsetOrFail(gameData, "CBasePlayer::m_nMovementTicksForUserCmdProcessingRemaining");
	char name[64];
	for (int i = 0; i < sizeof(userCmdInputs); i++)
	{
		FormatEx(name, sizeof(name), "CUserCmd::%s", userCmdInputs[i]);
		userCmdInputOffsets[i] = GetOffsetOrFail(gameData, name);
	}

	serverGameClients = GetInterfaceOrFail(gameData, "IServerGameClients");
	serverGameEnts = GetInterfaceOrFail(gameData, "IServerGameEnts");

	clientDisconnectCall = PrepPointerCallOrFail(gameData, "IServerGameClients::ClientDisconnect", false);
	freeContainingEntityCall = PrepPointerCallOrFail(gameData, "IServerGameEnts::FreeContainingEntity", false);
	baseEntityToEdictCall = PrepPointerCallOrFail(gameData, "IServerGameEnts::BaseEntityToEdict", true);

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Virtual, "CGameClient::Connect"))
	{
		SetFailState("Failed to get CGameClient::Connect offset");
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	botConnectCall = EndPrepSDKCall();
	if (botConnectCall == null)
	{
		SetFailState("Unable to prepare SDKCall for CGameClient::Connect");
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Virtual, "CGameClient::Disconnect"))
	{
		SetFailState("Failed to get CGameClient::Disconnect offset");
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	botDisconnectCall = EndPrepSDKCall();
	if (botDisconnectCall == null)
	{
		SetFailState("Unable to prepare SDKCall for CGameClient::Disconnect");
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Virtual, "CGameClient::ActivatePlayer"))
	{
		SetFailState("Failed to get CGameClient::ActivatePlayer offset");
	}
	activatePlayerCall = EndPrepSDKCall();
	if (activatePlayerCall == null)
	{
		SetFailState("Unable to prepare SDKCall for CGameClient::ActivatePlayer");
	}

	hooksToRemove = new ArrayList();
	offsetCheckConnectThis = GetOffsetOrFail(gameData, "CGameClient::CheckConnect_ThisOffset");
	int offset = GetOffsetOrFail(gameData, "CGameClient::CheckConnect");
	checkConnectHook = new DynamicHook(offset, HookType_Raw, ReturnType_Bool, ThisPointer_Address);
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetVirtual(offset);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	checkConnectCall = EndPrepSDKCall();
	if (checkConnectCall == null)
	{
		SetFailState("Unable to prepare SDKCall for CGameClient::CheckConnect");
	}

	signonStateHook = new DynamicHook(GetOffsetOrFail(gameData, "CGameClient::ProcessSignonStateMsg"), HookType_Raw, ReturnType_Bool, ThisPointer_Address);
	signonStateHook.AddParam(HookParamType_Int);
	signonStateHook.AddParam(HookParamType_Int);

	DynamicHook hook = CreateVirtualHookOrFail(gameData, "IServerGameClients::ClientPutInServer");
	hook.AddParam(HookParamType_Edict);
	hook.AddParam(HookParamType_CharPtr);
	hook.HookRaw(Hook_Pre, serverGameClients, DHooks_OnClientPutInServer);

	hook = CreateVirtualHookOrFail(gameData, "IServerGameClients::ClientDisconnect");
	hook.AddParam(HookParamType_Edict);
	hook.HookRaw(Hook_Pre, serverGameClients, DHooks_OnClientDisconnect);

	hook = CreateVirtualHookOrFail(gameData, "IServerGameClients::ClientSettingsChanged");
	hook.AddParam(HookParamType_Edict);
	hook.HookRaw(Hook_Pre, serverGameClients, DHooks_OnClientSettingsChanged);

	hook = CreateVirtualHookOrFail(gameData, "IServerGameClients::ClientActive");
	hook.AddParam(HookParamType_Edict);
	hook.AddParam(HookParamType_Bool);
	hook.HookRaw(Hook_Pre, serverGameClients, DHooks_OnClientActive);

	hook = CreateVirtualHookOrFail(gameData, "IServerGameEnts::FreeContainingEntity");
	hook.AddParam(HookParamType_Edict);
	hook.HookRaw(Hook_Pre, serverGameEnts, DHooks_OnFreeContainingEntity);

	Address engineServer = GetInterfaceOrFail(gameData, "IVEngineServer", "CreateInterface_Engine");
	hook = new DynamicHook(GetOffsetOrFail(gameData, "IVEngineServer::GetPlayerUserId"), HookType_Raw, ReturnType_Int, ThisPointer_Ignore);
	hook.AddParam(HookParamType_Edict);
	hook.HookRaw(Hook_Post, engineServer, DHooks_OnGetPlayerUserId);

	hook = new DynamicHook(GetOffsetOrFail(gameData, "IVEngineServer::GetPlayerNetworkIDString"), HookType_Raw, ReturnType_CharPtr, ThisPointer_Ignore);
	hook.AddParam(HookParamType_Edict);
	hook.HookRaw(Hook_Post, engineServer, DHooks_OnGetPlayerNetworkIDString);

	EnableDetourOrFail(gameData, "CBaseServer::ConnectClient", DHooks_OnConnectClient, DHooks_OnConnectClientPost);
	EnableDetourOrFail(gameData, "CBaseServer::GetFreeClientInternal", DHooks_OnGetFreeClient, DHooks_OnGetFreeClientPost);
	EnableDetourOrFail(gameData, "CGameServer::RemoveClientFromGame", DHooks_OnRemoveClientFromGame, INVALID_FUNCTION);

	delete gameData;
}



// =====[ HOOKS ]=====

public MRESReturn DHooks_OnConnectClient(Address server, DHookReturn hReturn, DHookParam hParams)
{
	if (server != gameServer)
	{
		return MRES_Ignored;
	}

	ReleaseExpiredHolds();
	inConnectClient = true;

	// The cookie starts with the claimed SteamID64; CheckChallengeType checks the ticket
	connectingAccountID = 0;
	Address cookie = hParams.Get(ConnectArg_Cookie);
	if (hParams.Get(ConnectArg_AuthProtocol) == STEAM_AUTH_PROTOCOL && hParams.Get(ConnectArg_CookieLength) >= 8 && cookie != Address_Null
		 && LoadFromAddress(cookie + view_as<Address>(4), NumberType_Int32) == STEAMID64_INDIVIDUAL_HIGH)
	{
		// Low 32 bits: account ID
		connectingAccountID = LoadFromAddress(cookie, NumberType_Int32);
	}

	routedClient = 0;
	int client = connectingAccountID != 0 && SteamChecksTickets() ? FindHeldClient(connectingAccountID) : 0;
	if (client != 0)
	{
		StopEngineBot(client);
		RouteRejoin(client);
	}
	return MRES_Ignored;
}

public MRESReturn DHooks_OnConnectClientPost(Address server, DHookReturn hReturn, DHookParam hParams)
{
	if (server != gameServer)
	{
		return MRES_Ignored;
	}

	// Non-null: the ticket matched the claimed SteamID
	if (routedClient != 0 && hReturn.Value != 0)
	{
		OnRejoinRouted(routedClient);
	}
	else if (routedClient != 0)
	{
		OnRejoinRefused(routedClient);
	}
	routedClient = 0;
	connectingAccountID = 0;
	inConnectClient = false;

	// The engine set it to the held userid, which would make later players reuse old userids
	if (savedUserIDCounter != -1)
	{
		StoreToAddress(gameServer + view_as<Address>(offsetUserIDCounter), savedUserIDCounter, NumberType_Int32, false);
		savedUserIDCounter = -1;
	}
	return MRES_Ignored;
}

public MRESReturn DHooks_OnGetFreeClient(Address server, DHookReturn hReturn, DHookParam hParams)
{
	if (server != gameServer)
	{
		return MRES_Ignored;
	}

	if (routedClient != 0)
	{
		hReturn.Value = GetBaseClient(routedClient);
		return MRES_Supercede;
	}

	// The original skips fake clients
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsHeld(client) && !IsEngineBot(client))
		{
			SetFakePlayerFlag(client, true);
		}
	}
	SkipHeldUserIDs();
	inGetFreeClient = true;
	return MRES_Ignored;
}

public MRESReturn DHooks_OnGetFreeClientPost(Address server, DHookReturn hReturn, DHookParam hParams)
{
	if (!inGetFreeClient)
	{
		return MRES_Ignored;
	}

	inGetFreeClient = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsHeld(client) && !IsEngineBot(client))
		{
			SetFakePlayerFlag(client, false);
		}
	}

	// Server full for a player (not CreateFakeClient): the oldest hold gives up its slot
	if (inConnectClient && hReturn.Value == 0)
	{
		int client = FindOldestHold();
		if (client != 0)
		{
			ReleaseForSlot(client);
			hReturn.Value = GetBaseClient(client);
			return MRES_Override;
		}
	}
	return MRES_Ignored;
}

public MRESReturn DHooks_OnRemoveClientFromGame(Address server, DHookParam hParams)
{
	gameServer = server;

	int client = GetClientOfBaseClient(hParams.Get(1));
	if (client == 0 || !OnEngineRemovesClient(client))
	{
		return MRES_Ignored;
	}
	return MRES_Supercede;
}

// A held slot answers "UNKNOWN", or "BOT" as the engine's bot, as in log lines
public MRESReturn DHooks_OnGetPlayerNetworkIDString(DHookReturn hReturn, DHookParam hParams)
{
	if (hParams.IsNull(1))
	{
		return MRES_Ignored;
	}

	int client = hParams.Get(1);
	if (client < 1 || client > MaxClients || !OwnsHeldUserID(client))
	{
		return MRES_Ignored;
	}

	char networkID[32];
	GetHeldNetworkID(client, networkID, sizeof(networkID));
	hReturn.SetString(networkID);
	return MRES_Override;
}

// No engine client for a held slot, so it would answer -1
public MRESReturn DHooks_OnGetPlayerUserId(DHookReturn hReturn, DHookParam hParams)
{
	if (hReturn.Value != -1 || hParams.IsNull(1))
	{
		return MRES_Ignored;
	}

	int client = hParams.Get(1);
	if (client < 1 || client > MaxClients || !OwnsHeldUserID(client))
	{
		return MRES_Ignored;
	}

	hReturn.Value = GetHeldUserID(client);
	return MRES_Override;
}

public MRESReturn DHooks_OnClientPutInServer(DHookParam hParams)
{
	return sourceModOnly || IsRejoining(hParams.Get(1)) ? MRES_Supercede : MRES_Ignored;
}

// SourceMod's own hook still runs when the game's function is superseded
public MRESReturn DHooks_OnClientDisconnect(DHookParam hParams)
{
	return sourceModOnly ? MRES_Supercede : MRES_Ignored;
}

// Would rename the body from the bot's empty settings
public MRESReturn DHooks_OnClientSettingsChanged(DHookParam hParams)
{
	return sourceModOnly ? MRES_Supercede : MRES_Ignored;
}

public MRESReturn DHooks_OnClientActive(DHookParam hParams)
{
	// The game would set the body up again
	if (sourceModOnly)
	{
		return MRES_Supercede;
	}

	int client = hParams.Get(1);
	if (!IsRejoining(client))
	{
		return MRES_Ignored;
	}

	OnRejoinActive(client);
	return MRES_Supercede;
}

public MRESReturn DHooks_OnFreeContainingEntity(DHookParam hParams)
{
	return IsRejoining(hParams.Get(1)) ? MRES_Supercede : MRES_Ignored;
}

public MRESReturn DHooks_OnCheckConnect(Address checkConnectThis, DHookReturn hReturn)
{
	int client = GetClientOfBaseClient(checkConnectThis - view_as<Address>(offsetCheckConnectThis));
	if (client == 0 || IsRunningDeferredConnect(client) || !IsRejoining(client))
	{
		return MRES_Ignored;
	}

	connectDeferred[client] = true;
	hReturn.Value = true;
	return MRES_Supercede;
}

// Signon SPAWN leads straight into ClientPutInServer
public MRESReturn DHooks_OnProcessSignonState(Address baseClient, DHookReturn hReturn, DHookParam hParams)
{
	int client = GetClientOfBaseClient(baseClient);
	if (client == 0 || !connectDeferred[client] || hParams.Get(1) != SIGNONSTATE_SPAWN)
	{
		return MRES_Ignored;
	}

	connectDeferred[client] = false;
	deferredConnectClient = client;
	OnDeferredConnect(client);
	bool accepted = SDKCall(checkConnectCall, baseClient + view_as<Address>(offsetCheckConnectThis));
	deferredConnectClient = 0;
	if (accepted)
	{
		return MRES_Ignored;
	}

	// CheckConnect has already disconnected the client
	hReturn.Value = false;
	return MRES_Supercede;
}



// =====[ PRIVATE ]=====

static Address GetBaseClient(int client)
{
	Address clients = LoadFromAddress(gameServer + view_as<Address>(offsetClients), NumberType_Int32);
	return LoadFromAddress(clients + view_as<Address>(4 * (client - 1)), NumberType_Int32);
}

static int GetClientOfBaseClient(Address baseClient)
{
	Address clients = LoadFromAddress(gameServer + view_as<Address>(offsetClients), NumberType_Int32);
	int count = LoadFromAddress(gameServer + view_as<Address>(offsetClientCount), NumberType_Int32);
	for (int slot = 0; slot < count && slot < MaxClients; slot++)
	{
		if (LoadFromAddress(clients + view_as<Address>(4 * slot), NumberType_Int32) == baseClient)
		{
			return slot + 1;
		}
	}
	return 0;
}

// GetNextUserID skips ids of clients the engine has but not held ones; skipping both
// leaves it on the id this loop stops at
static void SkipHeldUserIDs()
{
	Address counterAddr = gameServer + view_as<Address>(offsetUserIDCounter);
	int counter = LoadFromAddress(counterAddr, NumberType_Int32);
	int skipped = 0;
	while (skipped <= MaxClients && IsUserIDTaken((counter + 1) % 0x7FFF))
	{
		counter = (counter + 1) % 0x7FFF;
		skipped++;
	}
	if (skipped > 0)
	{
		StoreToAddress(counterAddr, counter, NumberType_Int32, false);
	}
}

static bool IsUserIDTaken(int userID)
{
	return IsHeldUserID(userID) || GetClientOfUserId(userID) != 0;
}

static void SetFakePlayerFlag(int client, bool fake)
{
	StoreToAddress(GetBaseClient(client) + view_as<Address>(offsetFakePlayer), fake, NumberType_Int8, false);
}

static int GetOffsetOrFail(GameData gameData, const char[] name)
{
	int offset = gameData.GetOffset(name);
	if (offset == -1)
	{
		SetFailState("Failed to get %s offset", name);
	}
	return offset;
}

static Address GetInterfaceOrFail(GameData gameData, const char[] key, const char[] createInterfaceSignature = "CreateInterface")
{
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, createInterfaceSignature))
	{
		SetFailState("Failed to get %s", createInterfaceSignature);
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle createInterface = EndPrepSDKCall();
	if (createInterface == null)
	{
		SetFailState("Unable to prepare SDKCall for %s", createInterfaceSignature);
	}

	char interfaceName[64];
	if (!gameData.GetKeyValue(key, interfaceName, sizeof(interfaceName)))
	{
		SetFailState("Failed to get %s interface name", key);
	}
	Address iface = SDKCall(createInterface, interfaceName, 0);
	delete createInterface;
	if (iface == Address_Null)
	{
		SetFailState("Failed to get %s pointer", key);
	}
	return iface;
}

static Handle PrepPointerCallOrFail(GameData gameData, const char[] name, bool returnsPointer)
{
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Virtual, name))
	{
		SetFailState("Failed to get %s offset", name);
	}
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	if (returnsPointer)
	{
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	}
	Handle call = EndPrepSDKCall();
	if (call == null)
	{
		SetFailState("Unable to prepare SDKCall for %s", name);
	}
	return call;
}

static DynamicHook CreateVirtualHookOrFail(GameData gameData, const char[] name)
{
	int offset = GetOffsetOrFail(gameData, name);
	return new DynamicHook(offset, HookType_Raw, ReturnType_Void, ThisPointer_Ignore);
}

static void EnableDetourOrFail(GameData gameData, const char[] name, DHookCallback pre, DHookCallback post)
{
	DynamicDetour detour = DynamicDetour.FromConf(gameData, name);
	if (detour == null)
	{
		SetFailState("Failed to set up %s detour", name);
	}
	if (!detour.Enable(Hook_Pre, pre) || post != INVALID_FUNCTION && !detour.Enable(Hook_Post, post))
	{
		SetFailState("Failed to enable %s detour", name);
	}
}
