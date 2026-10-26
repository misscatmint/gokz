/*
	gokz-rejoin Plugin Include

	Website: https://github.com/KZGlobalTeam/gokz
*/

#if defined _gokz_rejoin_included_
#endinput
#endif
#define _gokz_rejoin_included_



// =====[ FORWARDS ]=====

/**
 * Called when a disconnected player's slot starts being held.
 *
 * @param client		Client index.
 */
forward void GOKZ_RJ_OnHoldStart(int client);

/**
 * Called when a held slot is released without the player rejoining.
 *
 * @param client		Client index.
 */
forward void GOKZ_RJ_OnHoldEnd(int client);

/**
 * Called when a player has rejoined their held slot.
 *
 * @param client		Client index.
 */
forward void GOKZ_RJ_OnRejoin(int client);



// =====[ NATIVES ]=====

/**
 * Gets whether a client's slot is being held for them.
 *
 * @param client		Client index.
 * @return				Whether the slot is held.
 */
native bool GOKZ_RJ_IsHeld(int client);

/**
 * Gets whether the client's current connection rejoined a held slot.
 *
 * @param client		Client index.
 * @return				Whether the connection is a rejoin.
 */
native bool GOKZ_RJ_IsRejoin(int client);

/**
 * Gets whether a disconnect, in a player_disconnect hook, leaves the slot held.
 *
 * @param client		Client index.
 * @param reason		Disconnect reason from the event.
 * @return				Whether the slot is or will be held.
 */
native bool GOKZ_RJ_WillHold(int client, const char[] reason);

/**
 * Releases a held slot, delivering the deferred disconnect.
 *
 * @param client		Client index.
 */
native void GOKZ_RJ_Release(int client);

/**
 * Gets the Steam account ID of a held slot's player.
 *
 * @param client		Client index.
 * @return				Account ID, or 0 if the slot is not held.
 */
native int GOKZ_RJ_GetAccountID(int client);



// =====[ STOCKS ]=====

/**
 * GOKZ_RJ_IsHeld, false when gokz-rejoin is not loaded.
 *
 * @param client		Client index.
 * @return				Whether the slot is held.
 */
stock bool GOKZ_RJ_IsHeldIfAvailable(int client)
{
	return GetFeatureStatus(FeatureType_Native, "GOKZ_RJ_IsHeld") == FeatureStatus_Available
		&& GOKZ_RJ_IsHeld(client);
}

/**
 * GOKZ_RJ_IsRejoin, false when gokz-rejoin is not loaded.
 *
 * @param client		Client index.
 * @return				Whether the connection is a rejoin.
 */
stock bool GOKZ_RJ_IsRejoinIfAvailable(int client)
{
	return GetFeatureStatus(FeatureType_Native, "GOKZ_RJ_IsRejoin") == FeatureStatus_Available
		&& GOKZ_RJ_IsRejoin(client);
}

/**
 * GOKZ_RJ_WillHold, false when gokz-rejoin is not loaded.
 *
 * @param client		Client index.
 * @param reason		Disconnect reason from the event.
 * @return				Whether the slot is or will be held.
 */
stock bool GOKZ_RJ_WillHoldIfAvailable(int client, const char[] reason)
{
	return GetFeatureStatus(FeatureType_Native, "GOKZ_RJ_WillHold") == FeatureStatus_Available
		&& GOKZ_RJ_WillHold(client, reason);
}



// =====[ DEPENDENCY ]=====

public SharedPlugin __pl_gokz_rejoin =
{
	name = "gokz-rejoin",
	file = "gokz-rejoin.smx",
	#if defined REQUIRE_PLUGIN
	required = 1,
	#else
	required = 0,
	#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_gokz_rejoin_SetNTVOptional()
{
	MarkNativeAsOptional("GOKZ_RJ_IsHeld");
	MarkNativeAsOptional("GOKZ_RJ_IsRejoin");
	MarkNativeAsOptional("GOKZ_RJ_WillHold");
	MarkNativeAsOptional("GOKZ_RJ_Release");
	MarkNativeAsOptional("GOKZ_RJ_GetAccountID");
}
#endif
