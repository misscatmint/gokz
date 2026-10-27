static bool runHeld[MAXPLAYERS + 1];
static int heldAccountID[MAXPLAYERS + 1];
static bool runCarriedOver[MAXPLAYERS + 1];



// =====[ PUBLIC ]=====

bool GetRunHeld(int client)
{
	return runHeld[client];
}

int GetHeldAccountID(int client)
{
	return heldAccountID[client];
}

void SetRunHeld(int client, bool held, int accountID)
{
	runHeld[client] = held;
	heldAccountID[client] = held ? accountID : 0;
}

bool GetRunCarriedOver(int client)
{
	return runCarriedOver[client];
}

void SetRunCarriedOver(int client, bool carriedOver)
{
	runCarriedOver[client] = carriedOver;
}
