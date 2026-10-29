/*
	Sends a run to the global API and delete the replay if it is a temporary replay.
*/



enum struct PendingReplay
{
	char path[PLATFORM_MAX_PATH];
	bool temp;
}

// A run's record ID and its replay arrive in either order, so the first waits here for the other
static StringMap pendingRecordIds;
static StringMap pendingReplays;

enum struct UnverifiedRun
{
	int course;
	int mode;
	float time;
	int teleportsUsed;
}

// =====[ PUBLIC ]=====

void OnPluginStart_SendRun()
{
	pendingRecordIds = new StringMap();
	pendingReplays = new StringMap();
}

void OnMapEnd_SendRun()
{
	// Halves that never meet (no replay saved, or a failed API call) would pile up otherwise
	StringMapSnapshot keys = pendingReplays.Snapshot();
	char key[64];
	for (int i = 0; i < keys.Length; i++)
	{
		keys.GetKey(i, key, sizeof(key));
		DropPendingReplay(key);
	}
	delete keys;
	pendingRecordIds.Clear();
}

void SendTime(int client, int course, int mode, float time, int teleportsUsed)
{
	char steamid[32], modeStr[32], name[MAX_NAME_LENGTH];

	int timeType = GOKZ_GetTimeTypeEx(teleportsUsed);

	// If filters have been loaded, skip the submission when the API would reject it.
	if (gB_FiltersLoaded && course >= 0 && course < GOKZ_MAX_COURSES)
	{
		bool wouldSave = gB_HasFilter[course][mode][TimeType_Nub]
			|| (timeType == TimeType_Pro && gB_HasFilter[course][mode][TimeType_Pro]);
		if (!wouldSave)
		{
			return;
		}
	}

	GetClientName(client, name, sizeof(name));

	DataPack dp = CreateDataPack();
	dp.WriteCell(GetSteamAccountID(client));
	dp.WriteString(name);
	dp.WriteCell(course);
	dp.WriteCell(mode);
	dp.WriteCell(timeType);
	dp.WriteFloat(time);
	dp.WriteString(gC_CurrentMap);

	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
	GOKZ_GL_GetModeString(mode, modeStr, sizeof(modeStr));
	GlobalAPI_CreateRecord(SendTimeCallback, dp, steamid, gI_MapID, modeStr, course, 128, teleportsUsed, time);
}

void KeepUnverifiedRun(int client, int course, int mode, float time, int teleportsUsed)
{
	UnverifiedRun run;
	run.course = course;
	run.mode = mode;
	run.time = time;
	run.teleportsUsed = teleportsUsed;
	if (gA_UnverifiedRuns[client] == null)
	{
		gA_UnverifiedRuns[client] = new ArrayList(sizeof(UnverifiedRun));
	}
	gA_UnverifiedRuns[client].PushArray(run);
}

// Their replays aren't uploaded yet: GOKZ_RP_OnReplaySaved came before Steam verified the player.
void SendUnverifiedRuns(int client)
{
	if (gA_UnverifiedRuns[client] == null)
	{
		return;
	}

	UnverifiedRun run;
	for (int i = 0; i < gA_UnverifiedRuns[client].Length; i++)
	{
		gA_UnverifiedRuns[client].GetArray(i, run);
		SendTime(client, run.course, run.mode, run.time, run.teleportsUsed);
	}
	delete gA_UnverifiedRuns[client];
}

public int SendTimeCallback(JSON_Object response, GlobalAPIRequestData request, DataPack dp)
{
	char name[MAX_NAME_LENGTH];

	dp.Reset();
	int steamID = dp.ReadCell();
	dp.ReadString(name, sizeof(name));
	int course = dp.ReadCell();
	int mode = dp.ReadCell();
	int timeType = dp.ReadCell();
	float time = dp.ReadFloat();
	char mapName[64];
	dp.ReadString(mapName, sizeof(mapName));
	delete dp;

	char key[64];
	FormatRunKey(key, sizeof(key), steamID, course, timeType, time);

	if (request.Failure)
	{
		LogError("Failed to send a time to the global API.");
		if (GlobalAPI_HasAPIKey())
		{
			GlobalAPI_GetAuthStatus(GetAuthStatusCallback);
		}
		DropPendingReplay(key);
		return 0;
	}
	
	int top_place = response.GetInt("top_100");
	int top_overall_place = response.GetInt("top_100_overall");
	
	// The player may have left or reconnected since finishing
	int client = GOKZ_GetClientOfSteamAccountID(steamID);

	if (top_place > 0)
	{
		AnnounceNewTopTime(name, course, mode, timeType, top_place, top_overall_place);
		if (client != 0)
		{
			Call_OnNewTopTime(client, course, mode, timeType, top_place, top_overall_place, time, mapName);
		}
	}
	
	if (client != 0)
	{
		// Don't like doing this here, but seems to be the most efficient place
		UpdatePoints(client, true);
	}

	// Check if we can send the replay
	int recordId = response.GetInt("record_id");
	if (recordId == -1)
	{
		DropPendingReplay(key);
		return 0;
	}

	PendingReplay replay;
	if (pendingReplays.GetArray(key, replay, sizeof(replay)))
	{
		pendingReplays.Remove(key);
		SendReplay(recordId, replay.path, replay.temp);
	}
	else
	{
		pendingRecordIds.SetValue(key, recordId);
	}
	return 0;
}

public void OnReplaySaved_SendReplay(int client, int replayType, const char[] map, int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
	char key[64];
	FormatRunKey(key, sizeof(key), GetSteamAccountID(client), course, timeType, time);
	int recordId;
	if (pendingRecordIds.GetValue(key, recordId))
	{
		pendingRecordIds.Remove(key);
		SendReplay(recordId, filePath, tempReplay);
	}
	else
	{
		PendingReplay replay;
		strcopy(replay.path, sizeof(replay.path), filePath);
		replay.temp = tempReplay;
		pendingReplays.SetArray(key, replay, sizeof(replay));
	}
}

// The run's replay won't be uploaded, so a temporary one isn't needed any more
static void DropPendingReplay(const char[] key)
{
	PendingReplay replay;
	if (!pendingReplays.GetArray(key, replay, sizeof(replay)))
	{
		return;
	}
	pendingReplays.Remove(key);
	if (replay.temp)
	{
		DeleteFile(replay.path);
	}
}

static void FormatRunKey(char[] key, int maxlength, int steamID, int course, int timeType, float time)
{
	// Both halves carry the same float, so its bits match exactly
	FormatEx(key, maxlength, "%d_%d_%d_%d", steamID, course, timeType, view_as<int>(time));
}

static void SendReplay(int recordId, const char[] replayPath, bool temp)
{
	DataPack dp = new DataPack();
	dp.WriteString(temp ? replayPath : "");
	GlobalAPI_CreateReplayForRecordId(SendReplayCallback, dp, recordId, replayPath);
}

public int SendReplayCallback(JSON_Object response, GlobalAPIRequestData request, DataPack dp)
{
	// Delete the temporary replay file if needed.
	dp.Reset();
	char replayPath[PLATFORM_MAX_PATH];
	dp.ReadString(replayPath, sizeof(replayPath));
	if (replayPath[0] != '\0')
	{
		DeleteFile(replayPath);
	}
	delete dp;
	return 0;
}
