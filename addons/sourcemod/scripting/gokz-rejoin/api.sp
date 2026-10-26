static GlobalForward H_OnHoldStart;
static GlobalForward H_OnHoldEnd;
static GlobalForward H_OnRejoin;



// =====[ FORWARDS ]=====

void CreateGlobalForwards()
{
	H_OnHoldStart = new GlobalForward("GOKZ_RJ_OnHoldStart", ET_Ignore, Param_Cell);
	H_OnHoldEnd = new GlobalForward("GOKZ_RJ_OnHoldEnd", ET_Ignore, Param_Cell);
	H_OnRejoin = new GlobalForward("GOKZ_RJ_OnRejoin", ET_Ignore, Param_Cell);
}

void Call_OnHoldStart(int client)
{
	Call_StartForward(H_OnHoldStart);
	Call_PushCell(client);
	Call_Finish();
}

void Call_OnHoldEnd(int client)
{
	Call_StartForward(H_OnHoldEnd);
	Call_PushCell(client);
	Call_Finish();
}

void Call_OnRejoin(int client)
{
	Call_StartForward(H_OnRejoin);
	Call_PushCell(client);
	Call_Finish();
}



// =====[ NATIVES ]=====

void CreateNatives()
{
	CreateNative("GOKZ_RJ_IsHeld", Native_IsHeld);
	CreateNative("GOKZ_RJ_IsRejoin", Native_IsRejoin);
	CreateNative("GOKZ_RJ_WillHold", Native_WillHold);
	CreateNative("GOKZ_RJ_Release", Native_Release);
	CreateNative("GOKZ_RJ_GetAccountID", Native_GetAccountID);
}

public int Native_IsHeld(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsClientIndex(client))
	{
		return ThrowNativeError(SP_ERROR_PARAM, "Invalid client index %d", client);
	}
	// Still true while the release's disconnect runs
	return OwnsHeldUserID(client);
}

public int Native_IsRejoin(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsClientIndex(client))
	{
		return ThrowNativeError(SP_ERROR_PARAM, "Invalid client index %d", client);
	}
	return IsRejoin(client);
}

public int Native_WillHold(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsClientIndex(client))
	{
		return ThrowNativeError(SP_ERROR_PARAM, "Invalid client index %d", client);
	}
	char reason[128];
	GetNativeString(2, reason, sizeof(reason));
	return WillHold(client, reason);
}

public int Native_Release(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsClientIndex(client))
	{
		return ThrowNativeError(SP_ERROR_PARAM, "Invalid client index %d", client);
	}
	Release(client);
	return 0;
}

public int Native_GetAccountID(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsClientIndex(client))
	{
		return ThrowNativeError(SP_ERROR_PARAM, "Invalid client index %d", client);
	}
	return OwnsHeldUserID(client) && IsHeldVerified(client) ? GetHeldAccountID(client) : 0;
}

static bool IsClientIndex(int client)
{
	return client >= 1 && client <= MaxClients;
}
