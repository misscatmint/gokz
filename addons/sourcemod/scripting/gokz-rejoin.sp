/*
	Holds a disconnected runner's slot so a rejoin carries on the same run.

	- Hold: a player leaving or timing out with a running timer keeps their slot and entity,
	  SourceMod sees a bot there, so votes and player counts drop them.
	  The engine replays their last command with every input cleared, so physics, 
	  triggers and map logic carry on, gokz pauses them once its pause rules allow.
	  Spectators stay on the body throughout, and its player_disconnect is held back.
	- Rejoin: the same SteamID connecting is routed into the held slot under the old userid.
	  The game's ClientConnect is deferred to signon SPAWN, so the player is
	  never out of game while loading. SourceMod still sees a disconnect and a connect,
	  gokz-core's GOKZ_GetRunCarriedOver tells plugins it is one run.
	- Release: expiry, a kick, the run ending, a full server (oldest hold first) or plugin
	  unload fire the held player_disconnect and the real disconnect, a map change drops the hold.

	Steam:
	  sv_lan 1                           nothing is held, the engine checks no tickets
	  Ticket refused at connect          connection refused, hold kept
	  Ticket accepted                    resumed at once, nothing waits on Steam's verdict
	  Steam's verdict bad after resume   the engine drops them, held again unless banned
	  Steam down                         times save under the player's own account,
	                                     so not until Steam verifies them
*/

#include <sourcemod>

#include <cstrike>
#include <dhooks>
#include <sdkhooks>
#include <sdktools>

#include <gokz/core>
#include <gokz/rejoin>

#include <autoexecconfig>

#undef REQUIRE_EXTENSIONS
#undef REQUIRE_PLUGIN
#include <gokz/jumpstats>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo =
{
	name = "GOKZ Rejoin",
	author = "jvnipers",
	description = "Holds a disconnected runner's slot so they can rejoin and carry on",
	version = GOKZ_VERSION,
	url = GOKZ_SOURCE_URL
};

ConVar gCV_gokz_rejoin_hold_time;

#include "gokz-rejoin/api.sp"
#include "gokz-rejoin/away.sp"
#include "gokz-rejoin/engine.sp"
#include "gokz-rejoin/events.sp"
#include "gokz-rejoin/hold.sp"



// =====[ PLUGIN EVENTS ]=====

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNatives();
	RegPluginLibrary("gokz-rejoin");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("gokz-common.phrases");
	LoadTranslations("gokz-rejoin.phrases");

	CreateConVars();
	CreateGlobalForwards();
	OnPluginStart_Engine();
	OnPluginStart_Hold();
	OnPluginStart_Events();
	OnPluginStart_Away();
}

public void OnPluginEnd()
{
	ReleaseAllHolds();
}



// =====[ OTHER EVENTS ]=====

public void OnMapEnd()
{
	DropAllHolds();
}

public void OnGameFrame()
{
	RemoveUnusedHooks();
	ReleaseExpiredHolds();
	PauseHeldPlayers();
}

public void OnClientPutInServer(int client)
{
	OnClientPutInServer_Hold(client);
}

public void OnClientDisconnect(int client)
{
	OnClientDisconnect_Hold(client);
	OnClientDisconnect_Away(client);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	return OnPlayerRunCmd_Hold(client, angles) ? Plugin_Changed : Plugin_Continue;
}

public void GOKZ_OnTimerStopped(int client)
{
	if (IsHeld(client))
	{
		OnHeldTimerStopped(client);
	}
	OnTimerStopped_Hold(client);
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	if (IsHeld(client))
	{
		OnHeldRunFinished(client, course, time, teleportsUsed);
	}
	OnTimerStopped_Hold(client);
}



// =====[ PRIVATE ]=====

static void CreateConVars()
{
	AutoExecConfig_SetFile("gokz-rejoin", "sourcemod/gokz");
	AutoExecConfig_SetCreateFile(true);

	gCV_gokz_rejoin_hold_time = AutoExecConfig_CreateConVar(
		"gokz_rejoin_hold_time",
		"1800",
		"Seconds a disconnected runner's slot is held for them to rejoin (0 to disable).",
		_,
		true,
		0.0);

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
}
