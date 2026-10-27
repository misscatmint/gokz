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
 * Called when a held slot is released without the player rejoining,
 * also at a map change. It fires before the hold is torn down, while
 * GOKZ_GetRunHeld is still true for the slot.
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
 * Releases a held slot, delivering the deferred disconnect.
 * Does nothing for a slot that is not held or whose player is rejoining.
 *
 * @param client		Client index.
 */
native void GOKZ_RJ_Release(int client);



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
	MarkNativeAsOptional("GOKZ_RJ_Release");
}
#endif
