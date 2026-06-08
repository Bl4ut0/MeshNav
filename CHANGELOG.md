# Changelog - MeshNav

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-06-08
### Added
- **Hostile and Friendly Mob Tracking**: Scans nearby targets, focus, and nameplates (`nameplate1` to `nameplate40`) for NPCs.
- **Short GUID Hashing**: Hashes creature GUIDs into a compact 4-character hex string to fit within network packets.
- **Mesh-based Mob Trilateration**: Solves and tracks mob positions relative to group members dynamically using force-directed spring relaxation.
- **High Contrast Minimap UI**: Renders hostile mobs as bright solid red dots and friendly NPCs as bright solid green dots (clamped and faded when out of range).
- **Proximity Sorting**: Dynamic bandwidth management that sorts scanned mobs by proximity and limits broadcasts to the 5 closest active units.

## [1.0.0] - 2026-06-08
### Added
- Dynamic party (5-man) and raid (10 to 40-man) alphabetical roster indexing.
- Distance-checking engine using duel, inspect, and item ranges (30yd / 40yd).
- Real-time serialization and network synchronization via addon channel broadcasting (`MN_SYNC`).
- Verlet Relaxation Solver for smooth, coordinate-based relative positioning.
- Glassmorphic minimap HUD displaying range thresholds and class-colored unit dots.
- Text-to-Speech (TTS) manual announcements ("Announce Guide Position") via keybind option.
- Draggable frame movement and position saving.
