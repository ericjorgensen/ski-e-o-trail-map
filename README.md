# Trail Map Sign

A big wooden trail map board for your resort, like the ones at the top of real lifts. The map is
drawn from your own resort: every trail in its difficulty colour with its name, every lift, your
resort's name across the top, and a legend along the bottom.

## Using it

1. Open **Build > Decorations** and pick **Trail Map Sign** (next to Trail Markers).
2. Place it like any decoration. **Q** and **E** rotate it.
3. Click the board to see its info or bulldoze it. Like some other decorations, signs can't be
   moved; bulldoze and place a new one instead.

The map is drawn once, when the first sign appears. It doesn't update by itself, so it costs
nothing while you play. After you add or change trails or lifts, press **Ctrl+Alt+Y** to redraw
every sign. You can change that shortcut in the game's **Mods** menu.

Signs are saved with your resort and come back when you load it.

## Turning it off or removing it

Turning the mod off in the Mods menu turns every sign back into a plain Flag decoration, and they
become signs again when you turn it back on. If you uninstall the mod, saved resorts keep those
flags, so nothing breaks.

## How it works

The game's build menu can't take new items from a script, so the mod borrows a build-menu entry
the game ships switched off (an unused duplicate of Hanging Lanterns) and turns it into Trail Map
Sign. It only does this while that entry is still unused; if a game update ever puts it back to
use, Trail Map Sign stops appearing in Build and existing signs keep working.

Each sign is a Flag decoration that the mod hides and dresses with a board made from simple
shapes. The map image is shared by all signs.

## Compatibility

- Built and tested on Ski-e-o build CL7918 with Z's Mod Loader 1.5.2.
- Mods that also change the Hanging Lanterns entries in the build menu may conflict.
