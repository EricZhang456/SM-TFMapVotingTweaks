#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <nextmap>
#include <timers>

#include <nativevotes>

#pragma newdecls required

#define PLUGIN_VERSION "0.2.1"
public Plugin myinfo = {
    name = "[TF2] Map Voting Tweaks",
    author = "nosoop, Eric Zhang",
    description = "Modifications to TF2's native map vote system.",
    version = PLUGIN_VERSION,
    url = "https://github.com/EricZhang456/SM-TFMapVotingTweaks"
}

#define TABLE_SERVER_MAP_CYCLE "ServerMapCycle"
#define TABLEENTRY_SERVER_MAP_CYCLE "ServerMapCycle"

#define MAP_SANE_NAME_LENGTH 96

// Returns a full workshop name from a short name.
StringMap g_MapNameReference;

// Contains list of all maps from ServerMapCycle stringtable for restore on unload.
ArrayList g_FullMapList;

/* ConVar g_ConVarNextLevelAsNominate, g_ConVarEnforceExclusions; */

int g_iMapCycleStringTable, g_iMapCycleStringTableIndex;
bool g_bFinalizedMapCycleTable;

bool g_bNativeVotesLoaded;

public void OnPluginStart() {
	LoadTranslations("common.phrases");
	LoadTranslations("nominations.phrases");
	
	CreateConVar("sm_tfmapvote_version", PLUGIN_VERSION,
			"Current version of Map Voting Tweaks.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	
	g_FullMapList = new ArrayList(MAP_SANE_NAME_LENGTH);
	g_MapNameReference = new StringMap();
	
	AutoExecConfig();
}

public void OnMapEnd() {
	g_FullMapList.Clear();
	g_MapNameReference.Clear();
}

public void OnMapStart() {
	g_bFinalizedMapCycleTable = false;
	
	if ((g_iMapCycleStringTable = FindStringTable(TABLE_SERVER_MAP_CYCLE))
			== INVALID_STRING_TABLE) {
		SetFailState("Could not find %s stringtable", TABLE_SERVER_MAP_CYCLE);
	}
	
	if ((g_iMapCycleStringTableIndex =
			FindStringIndex(g_iMapCycleStringTable, TABLEENTRY_SERVER_MAP_CYCLE))
			== INVALID_STRING_INDEX) {
		SetFailState("Could not find %s string index in table %s.", TABLEENTRY_SERVER_MAP_CYCLE,
				TABLE_SERVER_MAP_CYCLE);
	}
	
	/**
	 * Process the mapcycle for late load.
	 * Doesn't fully resolve workshop maps otherwise.  See OnClientPostAdminCheck().
	 */
	ProcessServerMapCycleStringTable();
}

/**
 * Repopulates the map cycle table with all the maps it has acquired during the current map
 * (except shorthand workshop entries).
 */
public void OnPluginEnd() {
	if (g_FullMapList.Length > 0) {
		char mapName[MAP_SANE_NAME_LENGTH];
		
		StringMapSnapshot shorthandMapNames = g_MapNameReference.Snapshot();
		for (int i = 0; i < shorthandMapNames.Length; i++) {
			shorthandMapNames.GetKey(i, mapName, sizeof(mapName));
			
			int pos = g_FullMapList.FindString(mapName);
			if (pos > -1) {
				g_FullMapList.Erase(pos);
			}
		}
		
		ArrayList exportMapList = new ArrayList(MAP_SANE_NAME_LENGTH);
		
		// TODO remove "workshop/id" entries from written output iff long form exists?
		for (int i = 0; i < g_FullMapList.Length; i++) {
			g_FullMapList.GetString(i, mapName, sizeof(mapName));
			if (!IsWorkshopShortName(mapName)) {
				exportMapList.PushString(mapName);
			}
		}
		
		WriteServerMapCycleToStringTable(exportMapList);
		
		delete exportMapList;
	}
}

public void OnClientPostAdminCheck(int iClient) {
	/**
	 * Processing the table during an actual OnMapStart leaves short map workshop names that
	 * don't resolve to display names, so we're currently just going to process it when the
	 * first actual player is in-game, too.  It *should* be ready by then, riiiiight?
	 */
	if (!IsFakeClient(iClient) && g_bNativeVotesLoaded) {
		ProcessServerMapCycleStringTable();
		g_bFinalizedMapCycleTable = true;
	}
}

/**
 * Overrides the next level vote call with a sm_nextmap override.
 */
public Action OnNextLevelVoteCall(int client, NativeVotesOverride overrideType, const char[] voteArgument) {
	Handle vote = NatievVotes_Create(MapVoteHandler, NativeVotesType_NextLevel);
	NativeVotes_SetInitiator(vote, client);
	NativeVotes_SetDetails(voteArgument);
	NativeVotes_DisplayToAll(vote, 30);

	return Plugin_Handled;
}

/**
 * Overrides the change level vote call with an immediate map switch.
 */
public Action OnChangeLevelVoteCall(int client, NativeVotesOverride overrideType, const char[] voteArgument) {
	Handle vote = NatievVotes_Create(MapVoteHandler, NativeVotesType_ChgLevel);
	NativeVotes_SetInitiator(vote, client);
	NativeVotes_SetDetails(voteArgument);
	NativeVotes_DisplayToAll(vote, 30);

	return Plugin_Handled;
}

ArrayList ReadServerMapCycleFromStringTable() {
	int dataLength = GetStringTableDataLength(g_iMapCycleStringTable,
			g_iMapCycleStringTableIndex);
	
	char[] mapData = new char[dataLength];
	
	GetStringTableData(g_iMapCycleStringTable, g_iMapCycleStringTableIndex, mapData,
			dataLength);
	
	return ArrayListFromStringLines(mapData);
}

void WriteServerMapCycleToStringTable(ArrayList mapCycle) {
	PrintToServer("Writing %d maps to stringtable", mapCycle.Length);
	int dataLength = mapCycle.Length * MAP_SANE_NAME_LENGTH;
	char[] newMapData = new char[dataLength];
	StringLinesFromArrayList(mapCycle, newMapData, dataLength);
	
	bool bPreviousState = LockStringTables(false);
	SetStringTableData(g_iMapCycleStringTable, g_iMapCycleStringTableIndex, newMapData,
			dataLength);
	LockStringTables(bPreviousState);
}

/**
 * Handles map votes
 */
void MapVoteHandler(Handle vote, MenuAction action, int client, int items ) {
	char DisplayMap[MAP_SANE_NAME_LENGTH];
	NativeVotes_GetDetails(vote, DisplayMap, sizeof(DisplayMap));
	char map[MAP_SANE_NAME_LENGTH];
	ResolveMapDisplayName(DisplayMap, map, sizeof(map));

	switch ( action ) {
		case MenuAction_End: {
			NativeVotes_Close(vote);
		}

		case MenuAction_VoteCancel: {
			if ( client == VoteCancel_NoVotes ) {
				NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
			} else {
				NativeVotes_DisplayFail(vote, NativeVotesFail_Generic);
			}
		}

		case MenuAction_VoteEnd: {
			if ( client == NATIVEVOTES_VOTE_NO ) {
				NativeVotes_DisplayFail(vote, NativeVotesFail_Loses);
			} else {
				NativeVotes_DisplayPassEx(vote, NativeVotes_GetType(vote), DisplayMap);
				SetNextMap(map);
				if ( NativeVotes_GetType(vote) == "NativeVotesType_ChgLevel" ) {
					CreateTimer(1.0, FakeClientCommand(client, "changelevel_next"));
				}
			}
		}
	}
}

/**
 * Modifies the ServerMapCycle stringtable to provide shorthand map names.
 */
void ProcessServerMapCycleStringTable() {
	if (g_bFinalizedMapCycleTable || !g_bNativeVotesLoaded) {
		return;
	}
	
	ArrayList maps = ReadServerMapCycleFromStringTable();
	
	/**
	 * Map cycle isn't finalized, and if this is not the first run through some maps might have
	 * been removed.
	 */
	CopyUniqueStringArrayList(maps, g_FullMapList);
	
	ArrayList newMaps = new ArrayList(MAP_SANE_NAME_LENGTH);
	for (int m = 0; m < g_FullMapList.Length; m++) {
		char mapBuffer[MAP_SANE_NAME_LENGTH], shortMapBuffer[MAP_SANE_NAME_LENGTH];
		g_FullMapList.GetString(m, mapBuffer, sizeof(mapBuffer));
		
		GetMapDisplayName(mapBuffer, shortMapBuffer, sizeof(shortMapBuffer));
		
		if (!StrEqual(shortMapBuffer, mapBuffer, false)
				&& g_MapNameReference.SetString(shortMapBuffer, mapBuffer, true)) {
			// Is resolved workshop map name
			if (newMaps.FindString(shortMapBuffer) == -1) {
				newMaps.PushString(shortMapBuffer);
			}
		} else if (newMaps.FindString(mapBuffer) == -1) {
			// Is normal map name
			newMaps.PushString(mapBuffer);
		}
	}
	WriteServerMapCycleToStringTable(newMaps);
	
	delete newMaps;
	delete maps;
}

/**
 * Explodes a string by newlines, returning the individual strings as an ArrayList.
 */
ArrayList ArrayListFromStringLines(const char[] text) {
	int reloc_idx, idx;
	char buffer[PLATFORM_MAX_PATH];
	
	ArrayList result = new ArrayList(PLATFORM_MAX_PATH);
	
	while ((idx = SplitString(text[reloc_idx], "\n", buffer, sizeof(buffer))) != -1) {
		reloc_idx += idx;
		result.PushString(buffer);
	}
	result.PushString(buffer);
	return result;
}

/**
 * Joins strings from an ArrayList with newlines and stores it in buffer `result`.
 */
void StringLinesFromArrayList(ArrayList lines, char[] result, int length) {
	char buffer[PLATFORM_MAX_PATH];
	
	if (lines.Length > 0) {
		for (int i = 0; i < lines.Length; i++) {
			lines.GetString(i, buffer, sizeof(buffer));
			StrCat(result, length, buffer);
			StrCat(result, length, "\n");
		}
	}
}

void CopyUniqueStringArrayList(ArrayList src, ArrayList dest) {
	for (int i = 0; i < src.Length; i++) {
		char str[MAP_SANE_NAME_LENGTH];
		src.GetString(i, str, sizeof(str));
		
		if (dest.FindString(str) == -1) {
			dest.PushString(str);
		}
	}
}

bool IsWorkshopShortName(const char[] mapName) {
	return StrContains(mapName, "workshop/", true) == 0 && StrContains(mapName, ".ugc") == -1;
}

void ResolveMapDisplayName(const char[] displayName, char[] map, int maxlen) {
	// Resolve display names to full names
	if (!g_MapNameReference.GetString(displayName, map, maxlen)) {
		strcopy(map, maxlen, map);
	}
}

public void OnAllPluginsLoaded() {
	if (LibraryExists("nativevotes")) {
		OnNativeVotesLoaded();
	}
}

public void OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "nativevotes")) {
		OnNativeVotesLoaded();
	}
}

public void OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "nativevotes")) {
		OnNativeVotesLoaded();
	}
}

void OnNativeVotesLoaded() {
	g_bNativeVotesLoaded = true;
	
	NativeVotes_RegisterVoteCommand(NativeVotesOverride_NextLevel, OnNextLevelVoteCall);
	NativeVotes_RegisterVoteCommand(NativeVotesOverride_ChgLevel, OnChangeLevelVoteCall);
	
	// TODO unload support?
}