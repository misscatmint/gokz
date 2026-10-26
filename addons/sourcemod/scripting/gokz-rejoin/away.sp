enum struct AwayNote
{
	bool finished;
	int course;
	float time;
	int teleportsUsed;
	char reason[64]; // why the run was not kept
	int created;
}

// A note older than this is about a visit long gone
#define AWAY_NOTE_LIFETIME 3600

static StringMap awayNotes; // by Steam account ID
static AwayNote pendingNote[MAXPLAYERS + 1];
static bool fullyConnected[MAXPLAYERS + 1];



// =====[ PUBLIC ]=====

bool IsHeldRunFinished(int client)
{
	return pendingNote[client].finished;
}

// Where a hold ends without a rejoin; a finished run's note waits in pendingNote
void NoteHoldEnded(int client, const char[] reason)
{
	if (!pendingNote[client].finished)
	{
		strcopy(pendingNote[client].reason, sizeof(AwayNote::reason), reason);
	}
	SaveAwayNote(GetHeldAccountID(client), pendingNote[client]);
	pendingNote[client].finished = false;
}



// =====[ EVENTS ]=====

void OnPluginStart_Away()
{
	awayNotes = new StringMap();
}

void OnHoldStart_Away(int client)
{
	pendingNote[client].finished = false;
}

void OnHeldRunFinished(int client, int course, float time, int teleportsUsed)
{
	pendingNote[client].finished = true;
	pendingNote[client].course = course;
	pendingNote[client].time = time;
	pendingNote[client].teleportsUsed = teleportsUsed;
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

	if (!note.finished)
	{
		GOKZ_PrintToChat(client, true, "%t", "Away Run End (Not Kept)", note.reason);
		return;
	}
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



// =====[ PRIVATE ]=====

static void SaveAwayNote(int accountID, AwayNote note)
{
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
