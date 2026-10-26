enum AwayRunEnd
{
	AwayRunEnd_None = 0,
	AwayRunEnd_Finished,
	AwayRunEnd_RoundRestart,
	AwayRunEnd_Stopped,
	AwayRunEnd_Timeout,
	AwayRunEnd_MapChange,
	AwayRunEnd_ServerFull
}

enum struct AwayNote
{
	AwayRunEnd reason;
	int course;
	float time;
	int teleportsUsed;
	int holdMinutes;
	int created;
}

// A note older than this is about a visit long gone
#define AWAY_NOTE_LIFETIME 3600

static StringMap awayNotes; // by Steam account ID
static AwayNote pendingNote[MAXPLAYERS + 1];
static int timerStoppedTick[MAXPLAYERS + 1];
static int roundStartTick = -1;
static bool fullyConnected[MAXPLAYERS + 1];



// =====[ EVENTS ]=====

void OnPluginStart_Away()
{
	awayNotes = new StringMap();
	HookEvent("round_start", Event_RoundStart_Away, EventHookMode_PostNoCopy);
}

public void Event_RoundStart_Away(Event event, const char[] name, bool dontBroadcast)
{
	roundStartTick = GetGameTickCount();
}

void OnHeldRunFinished(int client, int course, float time, int teleportsUsed)
{
	pendingNote[client].reason = AwayRunEnd_Finished;
	pendingNote[client].course = course;
	pendingNote[client].time = time;
	pendingNote[client].teleportsUsed = teleportsUsed;
}

void OnHeldTimerStopped(int client)
{
	pendingNote[client].reason = AwayRunEnd_Stopped;
	timerStoppedTick[client] = GetGameTickCount();
}

// A frame late, so a round_start that stopped the timer is seen first
void NoteHeldRunEnd(int client)
{
	if (pendingNote[client].reason == AwayRunEnd_Stopped && timerStoppedTick[client] == roundStartTick)
	{
		pendingNote[client].reason = AwayRunEnd_RoundRestart;
	}
	SaveAwayNote(GetHeldAccountID(client), pendingNote[client]);
	pendingNote[client].reason = AwayRunEnd_None;
}

void NoteHoldEnded(int client, AwayRunEnd reason)
{
	AwayNote note;
	note.reason = reason;
	note.holdMinutes = GetHoldMinutes(client);
	SaveAwayNote(GetHeldAccountID(client), note);
	pendingNote[client].reason = AwayRunEnd_None;
}

// First point chat reaches the client
void OnClientFullyConnected_Away(int client)
{
	fullyConnected[client] = true;
	ShowAwayNote(client);
}

void OnClientDisconnect_Away(int client)
{
	fullyConnected[client] = false;
}

// Shown now if chat reaches the client, else once it does
void ShowAwayNote(int client)
{
	if (!fullyConnected[client])
	{
		return;
	}

	char key[16];
	IntToString(GetSteamAccountID(client, false), key, sizeof(key));
	AwayNote note;
	if (!awayNotes.GetArray(key, note, sizeof(note)))
	{
		return;
	}
	awayNotes.Remove(key);
	if (GetTime() - note.created > AWAY_NOTE_LIFETIME)
	{
		return;
	}

	switch (note.reason)
	{
		case AwayRunEnd_Finished:
		{
			char timeType[4];
			timeType = note.teleportsUsed > 0 ? "TP" : "PRO";
			if (note.course == 0)
			{
				GOKZ_PrintToChat(client, true, "%t", "Away Run End (Finished Map)", timeType, GOKZ_FormatTime(note.time));
			}
			else
			{
				GOKZ_PrintToChat(client, true, "%t", "Away Run End (Finished Bonus)", note.course, timeType, GOKZ_FormatTime(note.time));
			}
		}
		case AwayRunEnd_RoundRestart:
		{
			GOKZ_PrintToChat(client, true, "%t", "Away Run End (Round Restart)");
		}
		case AwayRunEnd_Stopped:
		{
			GOKZ_PrintToChat(client, true, "%t", "Away Run End (Stopped)");
		}
		case AwayRunEnd_Timeout:
		{
			GOKZ_PrintToChat(client, true, "%t", "Away Run End (Timeout)", note.holdMinutes);
		}
		case AwayRunEnd_MapChange:
		{
			GOKZ_PrintToChat(client, true, "%t", "Away Run End (Map Change)");
		}
		case AwayRunEnd_ServerFull:
		{
			GOKZ_PrintToChat(client, true, "%t", "Away Run End (Server Full)");
		}
	}
}



// =====[ PRIVATE ]=====

static void SaveAwayNote(int accountID, AwayNote note)
{
	if (note.reason == AwayRunEnd_None)
	{
		return;
	}

	PruneAwayNotes();
	note.created = GetTime();
	char key[16];
	IntToString(accountID, key, sizeof(key));
	awayNotes.SetArray(key, note, sizeof(note));
}

static void PruneAwayNotes()
{
	StringMapSnapshot keys = awayNotes.Snapshot();
	char key[16];
	AwayNote note;
	for (int i = 0; i < keys.Length; i++)
	{
		keys.GetKey(i, key, sizeof(key));
		if (awayNotes.GetArray(key, note, sizeof(note)) && GetTime() - note.created > AWAY_NOTE_LIFETIME)
		{
			awayNotes.Remove(key);
		}
	}
	delete keys;
}
