/*
	Keeps a player's run going while they are away, so they can rejoin and carry on.

	1. A player who leaves with a running timer is held: their slot and body stay, with every
	   input cleared, so the run plays out as if they stood still, and gokz pauses it once its
	   pause rules allow. SourceMod sees a bot in the slot, so votes and player counts leave
	   them out. The hold lasts gokz_rejoin_hold_time.
	2. The same account connecting again is routed into the held slot, under the old userid,
	   and resumes where the body is.
	3. The run's end (finished, stopped, or the hold expiring) ends the hold, and the player
	   is told what became of their timer on their next visit.
	4. On a full server, gokz_rejoin_full_server decides whether held slots give way to new
	   players (the hold with the least time on its timer goes first, unless the newcomer is
	   a held account retrying) or stay reserved. Give way is the default: a player who can
	   play now beats a run that may never be resumed.
	5. A resumed run counts like any other: it saves and submits under the player's account
	   once Steam has verified them.

	Limits:
	- sv_lan 1: Steam checks no ticket, so a forged SteamID can take over a held run.
	  Griefing only, since nothing saves or submits for it.
	- sv_maxusrcmdprocessticks 0: nothing is held, as the body needs the engine's command replay.
	- A crashed player's old connection lingers until the engine times it out (65 s in game,
	  300 s while loading), and Steam refuses their new connection until then.
	- A rejoin whose connection dies while loading blocks retries for up to 300 s the same way.
	- With give way, a connect refused after the slot was chosen (a forged ticket from a real
	  address, a banned player retrying, a crash retry by a player Steam hasn't verified yet)
	  still costs a held run.

	The engine mechanics are explained at the hooks.
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
ConVar gCV_gokz_rejoin_full_server;

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
	return OnPlayerRunCmd_Hold(client, buttons, impulse, vel, angles, weapon, subtype, cmdnum, mouse) ? Plugin_Changed : Plugin_Continue;
}

public void GOKZ_OnTimerStopped(int client)
{
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
	gCV_gokz_rejoin_full_server = AutoExecConfig_CreateConVar(
		"gokz_rejoin_full_server",
		"0",
		"On a full server, held slots give way to new players (0) or stay reserved (1).",
		_,
		true,
		0.0,
		true,
		1.0);

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
}
