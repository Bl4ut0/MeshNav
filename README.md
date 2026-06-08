# MeshNav - Distributed Relative Positioning System for WoW Classic

MeshNav is a relative positioning HUD addon designed for World of Warcraft Classic (TBC 2.5.5 and Vanilla 1.15.8) dungeons/instances where native absolute positioning APIs (`UnitPosition`, `C_Map.GetPlayerMapPosition`) are disabled.

By constructing a local mesh network using discrete range-check APIs and inter-client broadcasting, MeshNav generates a real-time HUD showing the approximate locations of party/raid members relative to the local player, complete with Text-to-Speech (TTS) accessibility navigation tools.

---

## 🚀 Key Features

*   **Real-time 2D minimap HUD**: A circular, glassmorphic HUD showing party/raid members as class-colored dots.
*   **Concentric Range Rings**: Displays range boundaries at **10yd**, **28yd**, and **40yd** thresholds.
*   **Dynamic Group Support**: Automatically scales from standard **5-man parties** to **10-man and 40-man raid groups** by alphabetically sorting rosters deterministically.
*   **Keybind-Based Text-to-Speech (TTS)**: Trigger-based spatial feedback (e.g. *"Tank at 2 o'clock, 18 yards"*) designed for blind and visually impaired player navigation.
*   **Target Locking**: Set a designated player (like the Tank or healer) as your "Guide" (via right-click on their HUD dot or `/mn guide <name>`) to lock-on your TTS feedback.
*   **Auto-Clamping Out-of-Range Units**: Clamps units beyond 40 yards to the outer rim of the radar at `40% opacity`, showing their last known vector.
*   **PowerShell Developer Tools**: Automatic version-bumping deployment scripts and SavedVariables history logs parsers.

---

## 🛠️ Installation

1. Download the repository source.
2. Copy the contents of the repository root (specifically `MeshNav.toc`, `MeshNav.lua`, and `Bindings.xml`) into your WoW addons folder inside a new folder named `MeshNav`:
   `World of Warcraft\_classic_\Interface\AddOns\MeshNav\`
3. Restart WoW or check the Addon list on the character selection screen to verify `MeshNav` is enabled.

---

## 🎮 In-Game Guide & Commands

### Slash Commands
Use `/mn` or `/meshnav` to access controls:
*   `/mn show` / `/mn hide`: Toggle HUD radar visibility.
*   `/mn lock`: Toggle frame dragging lock (allows you to reposition the HUD).
*   `/mn guide <name>`: Manually assign a guide target by name.
*   `/mn clear`: Clear the current guide lock-on.
*   `/mn tts`: Speak the guide's relative distance and clock direction immediately.
*   `/mn speak`: Toggle periodic automatic speech updates (disabled by default).
*   `/mn interval <seconds>`: Adjust the frequency of periodic speech updates (default 5s).
*   `/mn log`: Toggle SavedVariables database matrix history logging.
*   `/mn clearlog`: Clear history log database.

### Setting Up the Accessibility Keybind
MeshNav registers a native action in WoW's options menu so you can ping your guide's position at the push of a button:
1. Open the game menu (**Esc**) and navigate to **Keybindings** (or Options -> Keybindings).
2. Scroll to the **Mesh-Radar Addon** header.
3. Bind a key (e.g., Numpad 5, or `F`) to **Announce Guide Position (TTS)**.
4. Push this hotkey during your dungeon runs to hear spatial coordinates relative to your character (where 12 o'clock is straight ahead).

---

## 🔬 How It Works (The Math)

1.  **Distance Bucket Vector**: Every client measures distance to all active group members using boolean checks:
    *   `0-10 yds`: Duel inspect range (`CheckInteractDistance(unit, 3)`)
    *   `10-28 yds`: Follow inspect range (`CheckInteractDistance(unit, 1)`)
    *   `28-30 yds`: 30yd item range check (`IsItemInRange(itemID_30, unit)`)
    *   `30-40 yds`: 40yd item range check (`IsItemInRange(itemID_40, unit)`)
    *   `40+ yds`: Out-of-range fallback
2.  **Broadcasting**: Each client serializes their distance vector (e.g. `3:24015`) and broadcasts it to the group via `C_ChatInfo.SendAddonMessage` on prefix `MN_SYNC` every 0.5s.
3.  **Trilateration (Verlet Relaxation)**: 
    *   The client solves the 2D constellation coordinates by treating distances as spring constraints.
    *   The local player is anchored at $(0, 0)$.
    *   The solver runs 30 iterations of relaxation per frame.
    *   Calculated coordinates are smoothed using a $15\%$ linear interpolation per frame to eliminate jitter.

---

## 💻 Developer Resources

For details on local deployment tools, versioning bumps, and database migration protocols, please refer to the [Deployment Guide](file:///c:/Dev%20Projects/MeshLPS/docs/DEPLOYMENT.md).

*   [Deploy.ps1](file:///c:/Dev%20Projects/MeshLPS/Deploy.ps1): Automatically bumps version tokens in `MeshNav.toc` / `MeshNav.lua` and copies release files to your WoW folder.
*   [ParseLogs.ps1](file:///c:/Dev%20Projects/MeshLPS/ParseLogs.ps1): Extracts and formats the matrix logs database from SavedVariables.
*   [.pkgmeta](file:///c:/Dev%20Projects/MeshLPS/.pkgmeta): CurseForge packaging filters to exclude dev files from releases.
*   [.cursorrules](file:///c:/Dev%20Projects/MeshLPS/.cursorrules): Coding constraints and API rules for AI code assistants.
