/*
	Processes a newly submitted time, determining if the player beat their
	personal best and if they beat the map course and mode's record time.
*/



void DB_ProcessNewTime(int steamID, const char[] name, int mapID, int course, int mode, int style, int runTimeMS, int teleportsUsed)
{
	char query[1024];
	
	DataPack data = new DataPack();
	data.WriteCell(steamID);
	data.WriteString(name);
	data.WriteCell(mapID);
	data.WriteCell(course);
	data.WriteCell(mode);
	data.WriteCell(style);
	data.WriteCell(runTimeMS);
	data.WriteCell(teleportsUsed);
	
	Transaction txn = SQL_CreateTransaction();
	
	// Get Top 2 PBs
	FormatEx(query, sizeof(query), sql_getpb, steamID, mapID, course, mode, 2);
	txn.AddQuery(query);
	// Get Rank
	FormatEx(query, sizeof(query), sql_getmaprank, mapID, course, mode, steamID, mapID, course, mode);
	txn.AddQuery(query);
	// Get Number of Players with Times
	FormatEx(query, sizeof(query), sql_getlowestmaprank, mapID, course, mode);
	txn.AddQuery(query);
	
	if (teleportsUsed == 0)
	{
		// Get Top 2 PRO PBs
		FormatEx(query, sizeof(query), sql_getpbpro, steamID, mapID, course, mode, 2);
		txn.AddQuery(query);
		// Get PRO Rank
		FormatEx(query, sizeof(query), sql_getmaprankpro, mapID, course, mode, steamID, mapID, course, mode);
		txn.AddQuery(query);
		// Get Number of Players with PRO Times
		FormatEx(query, sizeof(query), sql_getlowestmaprankpro, mapID, course, mode);
		txn.AddQuery(query);
	}
	
	SQL_ExecuteTransaction(gH_DB, txn, DB_TxnSuccess_ProcessTimerEnd, DB_TxnFailure_Generic_DataPack, data, DBPrio_Normal);
}

public void DB_TxnSuccess_ProcessTimerEnd(Handle db, DataPack data, int numQueries, Handle[] results, any[] queryData)
{
	char name[MAX_NAME_LENGTH];

	data.Reset();
	int steamID = data.ReadCell();
	data.ReadString(name, sizeof(name));
	int mapID = data.ReadCell();
	int course = data.ReadCell();
	int mode = data.ReadCell();
	int style = data.ReadCell();
	int runTimeMS = data.ReadCell();
	int teleportsUsed = data.ReadCell();
	delete data;
	
	bool firstTime = SQL_GetRowCount(results[0]) == 1;
	int pbDiff = 0;
	int rank = -1;
	int maxRank = -1;
	if (!firstTime)
	{
		SQL_FetchRow(results[0]);
		int pb = SQL_FetchInt(results[0], 0);
		if (runTimeMS == pb) // New time is new PB
		{
			SQL_FetchRow(results[0]);
			int oldPB = SQL_FetchInt(results[0], 0);
			pbDiff = runTimeMS - oldPB;
		}
		else // Didn't beat PB
		{
			pbDiff = runTimeMS - pb;
		}
	}
	// Get NUB Rank
	SQL_FetchRow(results[1]);
	rank = SQL_FetchInt(results[1], 0);
	SQL_FetchRow(results[2]);
	maxRank = SQL_FetchInt(results[2], 0);
	
	// Repeat for PRO Runs
	bool firstTimePro = false;
	int pbDiffPro = 0;
	int rankPro = -1;
	int maxRankPro = -1;
	if (teleportsUsed == 0)
	{
		firstTimePro = SQL_GetRowCount(results[3]) == 1;
		if (!firstTimePro)
		{
			SQL_FetchRow(results[3]);
			int pb = SQL_FetchInt(results[3], 0);
			if (runTimeMS == pb) // New time is new PB
			{
				SQL_FetchRow(results[3]);
				int oldPB = SQL_FetchInt(results[3], 0);
				pbDiffPro = runTimeMS - oldPB;
			}
			else // Didn't beat PB
			{
				pbDiffPro = runTimeMS - pb;
			}
		}
		// Get PRO Rank
		SQL_FetchRow(results[4]);
		rankPro = SQL_FetchInt(results[4], 0);
		SQL_FetchRow(results[5]);
		maxRankPro = SQL_FetchInt(results[5], 0);
	}
	
	// The player may have left or reconnected since finishing
	int client = GOKZ_GetClientOfSteamAccountID(steamID);
	bool currentMap = mapID == GOKZ_DB_GetCurrentMapID();

	if (currentMap)
	{
		AnnounceNewTime(name, course, mode, GOKZ_DB_TimeIntToFloat(runTimeMS), teleportsUsed, firstTime, GOKZ_DB_TimeIntToFloat(pbDiff), rank, maxRank, firstTimePro, GOKZ_DB_TimeIntToFloat(pbDiffPro), rankPro, maxRankPro);
	}

	// Call OnTimeProcessed forward
	if (client != 0)
	{
		Call_OnTimeProcessed(
			client,
			steamID,
			mapID,
			course,
			mode,
			style,
			GOKZ_DB_TimeIntToFloat(runTimeMS),
			teleportsUsed,
			firstTime,
			GOKZ_DB_TimeIntToFloat(pbDiff),
			rank,
			maxRank,
			firstTimePro,
			GOKZ_DB_TimeIntToFloat(pbDiffPro),
			rankPro,
			maxRankPro);
	}
	
	bool newWR = (firstTime || pbDiff < 0) && rank == 1;
	bool newWRPro = (firstTimePro || pbDiffPro < 0) && rankPro == 1;
	if (!newWR && !newWRPro)
	{
		return;
	}

	int recordType = newWR && newWRPro ? RecordType_NubAndPro : (newWR ? RecordType_Nub : RecordType_Pro);
	int recordPBDiff = newWRPro ? pbDiffPro : pbDiff;

	if (currentMap)
	{
		AnnounceNewRecord(name, course, mode, recordType);
		DB_CacheRecords(mapID);
	}

	// Call OnNewRecord forward
	if (client != 0)
	{
		Call_OnNewRecord(client, steamID, mapID, course, mode, style, recordType, GOKZ_DB_TimeIntToFloat(recordPBDiff), teleportsUsed);
	}
} 