OStim Node Diet - fix for the random OStim CTD when large animation packs are installed
==========================================================================================

!! VIBE-CODED !!
The investigation and all code here were done together with an AI coding assistant
(Claude Code). I tested it on my own load order and it fixed my crash, but I am not a
Skyrim engine / Havok expert. Treat it as experimental: read the script if you like
(it is plain PowerShell), keep the automatic backup, and report problems.


!! READ BEFORE USING !!
Only run this tool if you're actually getting the OStim crash described below
(hkbBehaviorGraph::GlobalTransitionData / mov rax,[rdx+0x10] in your crash log).
If your game is running fine, don't use it. Reshuffling the nodes changes which state
machines share an ID, so if your setup is still over the limit, it can move the collision
onto an OStim node and cause the exact crash it's meant to fix.
The 65,536 limit counts all behavior files, not just 0_Master. Big SexLab / SLAL /
Devious Devices setups add a lot of FNIS behavior nodes this tool can't shrink.
If you crash after using it, roll back (run Pandora again or use Rollback.bat).


THE CRASH THIS FIXES
--------------------
Random CTD when an OStim scene starts or switches animation, usually only with many
animation packs installed. Crash log (CrashLoggerSSE / Trainwreck) looks like:

  EXCEPTION_ACCESS_VIOLATION at SkyrimSE.exe+0AF724B   (offset is for 1.7.104)
  mov rax, [rdx+0x10]          (rdx = 0)
  objects on the stack: RootBehaviorGraph, "<SomePack>_Root", hkbBehaviorGraph::GlobalTransitionData

Typical behaviour: which pack crashes changes every time you rebuild in Pandora,
unticking a few packs "fixes" it, and the same scene sometimes works and sometimes
crashes. Raising the Open Animation Replacer limit or Engine Fixes does not help.


WHY IT HAPPENS
--------------
Havok (Skyrim's animation engine) numbers every behavior node with a 16-bit id, so there
are only 65,536 ids. The character behavior graph = 0_Master.hkx + vanilla sub-behaviors
(dialogue, idles, ...) + FNIS behaviors. Each OStim pack animation is built as 3 nodes
(state wrapper + BSIsActiveModifier + clip), so with ~12,000+ pack animations 0_Master
alone reached ~52,000 nodes on my setup, and the total went past 65,536.

Past that point ids wrap around and collide. Havok keeps an id -> state machine lookup
table that only holds one entry per id, so a pack's root state machine gets overwritten by
a vanilla one (e.g. DialogueRightBlend01) that has no global transitions. OStim then asks
for the pack's global transitions, gets nothing, and the game crashes. It is random because
the vanilla sub-behaviors are loaded lazily (e.g. when someone talks), so the collision
happens or not depending on what was loaded first.


WHAT THIS TOOL DOES
-------------------
In every OStim pack, each animation has its own identical wrapper (a ModifierGenerator with
a BSIsActiveModifier that sets bAnimationDriven while the animation plays). The tool rewires
the pointers in 0_Master.hkx so that ONE of those wrappers wraps the whole pack, and every
animation state points straight at its clip. Same effect in game (bAnimationDriven is on
while any animation of the pack is playing), about 2 nodes fewer per animation.

On my setup: 69 packs, 12,713 animations, 0_Master went from 51,896 to 26,608 nodes.

- Only pointer targets in the file's fixup table are changed. File size stays the same,
  no animation is removed.
- Before writing, it simulates the result and checks the node count matches exactly what
  is expected. If anything looks unusual it aborts and does not touch the file.
- Packs whose structure doesn't match the expected pattern are left alone.
- Backup is saved next to the file as 0_Master.hkx.original.


REQUIREMENTS
------------
- Windows with PowerShell 5.1 (built into Windows 10/11). Nothing to install.
- Behavior file built by Pandora Behaviour Engine. Tested with Pandora 5.0.0-beta,
  Skyrim SE 1.7.104, OStim Standalone packs. Nemesis output was not tested.
- The tool edits a file, it does not touch the game exe, so it should not depend on the
  game version - but only 1.7.104 was tested.


HOW TO USE
----------
1. Run Pandora as usual.
2. Double-click "Run Node Diet.bat". A file picker opens - select the 0_Master.hkx
   Pandora just built. It is in meshes\actors\character\behaviors\ inside the folder
   Pandora outputs to, which depends on your setup:
     - MO2: the mod folder you set as Pandora's output (e.g. MO2\mods\Pandora Output),
       or MO2\overwrite if you didn't set one
     - Vortex / manual: Skyrim Special Edition\Data
   Not sure? Check the output path in Pandora's settings, or search for 0_Master.hkx
   and pick the newest one.
3. Wait until it prints "Done." (about 1-3 minutes, it is slow PowerShell).

The file is edited WHERE IT IS - do not move or copy it anywhere. The backup
(0_Master.hkx.original) is created right next to it.

IMPORTANT: every time you run Pandora again, it rebuilds the full file - run the tool again
afterwards. If the file is already processed, the tool just says "Nothing to do".


ROLLBACK / UNINSTALL
--------------------
- Run Pandora again (gives you the untouched file), or
- run "Rollback.bat" and select the same 0_Master.hkx (restores 0_Master.hkx.original).
  Rollback refuses if Pandora was run again since, because the backup would be outdated.
A log of every run is written to OStimNodeDiet.log next to the script.


KNOWN LIMITS / RISKS
--------------------
- If you see actors sliding or misaligned, or a pack behaving differently than before,
  roll back and report it (that is the one place where the rewiring could differ).
- The limit counts all character behaviors, not only 0_Master. If you still crash with the
  same signature, you may have huge FNIS behavior mods too.
- The real fix belongs in the behavior engine (generate one wrapper per pack instead of per
  animation). If Pandora / OStim ever do that, this tool will just report "Nothing to do".


FOR MOD AUTHORS (technical notes, 1.7.104 offsets)
--------------------------------------------------
- Node ids are assigned as int16 at SkyrimSE.exe+ACEA0A (node->m_id = (int16)index) for
  all nodes of the character graph, including linked sub-behaviors.
- The id -> state machine template map lives at (behaviorGraph+0xB0)+0x50 (hkPointerMap,
  lookup at +AA6960). Global (wildcard) transition resolution at +AF71C0 reads
  map[stateMachineId]->m_wildcardTransitions (+0xA0) and dereferences it without a null
  check -> crash at +AF724B when the slot holds a different state machine.
- Pack layout in 0_Master: StateInfo(+0x58) -> hkbModifierGenerator { modifier(+0x48) =
  BSIsActiveModifier binding bIsActive0 -> bAnimationDriven, generator(+0x50) =
  hkbClipGenerator }.


License: MIT - do what you want with it, no warranty.
