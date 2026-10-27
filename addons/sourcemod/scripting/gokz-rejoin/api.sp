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
	CreateNative("GOKZ_RJ_Release", Native_Release);
}

public int Native_Release(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsClientIndex(client))
	{
		return ThrowNativeError(SP_ERROR_PARAM, "Invalid client index %d", client);
	}
	Release(client, "Released by a plugin");
	return 0;
}

static bool IsClientIndex(int client)
{
	return client >= 1 && client <= MaxClients;
}
