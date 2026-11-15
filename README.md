# DockKeeper

A tiny, free macOS menu bar app that stops the Dock from jumping between monitors.

If you use more than one display, macOS moves the Dock to whichever screen you push the cursor against at the bottom edge. DockKeeper keeps the Dock on your main display (the one with the menu bar) and leaves it there.

- No Dock icon, no nag screens, no subscription
- A lock icon in the menu bar with Pause, Launch at Login, Help, and Quit
- Hold **Control + Option** while pushing down if you want to move the Dock on purpose
- Picks up display changes automatically (plugging in, unplugging, rearranging)
- Nothing in the system is modified and nothing is injected into the Dock

## How it works

macOS moves the Dock when the cursor hits the bottom edge of another display and keeps pushing. DockKeeper watches mouse movement and holds the cursor 2 points above the bottom edge of every display except the main one. The Dock never sees the trigger. If another display sits directly below, that edge is left open so you can still move between the screens.

All of it is in one file, `main.swift`, under 200 lines, so anyone can read exactly what it does.

## Install

### Option A: download the app

1. Download `DockKeeper.zip` from the [Releases](../../releases) page and unzip it.
2. Move `DockKeeper.app` to your Applications folder.
3. Open it. macOS will block it the first time because it is not signed with a paid Apple developer certificate. The quickest way past that is to paste this into Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/DockKeeper.app && open /Applications/DockKeeper.app
   ```

   Or go to **System Settings > Privacy & Security**, scroll to the very bottom, and click **Open Anyway**. See Troubleshooting below.
4. When asked, allow DockKeeper under **System Settings > Privacy & Security > Accessibility**. It starts working within a couple of seconds.
5. Click the lock icon in the menu bar and turn on **Launch at Login**.

### Option B: build it yourself

Requires Apple's Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/ral605/doc-keeper.git
cd doc-keeper
./build.sh
open ~/Applications/DockKeeper.app
```

Then do steps 4 and 5 above. Building it yourself avoids the security warning.

## Using it

Click the lock icon in the menu bar:

| Menu item | What it does |
|---|---|
| Status line | Shows whether the Dock is locked or paused. If it says it needs permission, click it to open the Accessibility settings. |
| Pause | Lets the Dock move normally until you turn it back on. The icon changes to an open lock. |
| Launch at Login | Starts DockKeeper automatically when you log in. |
| Help… | Opens this page. |
| Quit DockKeeper | Stops it. |

To move the Dock to another screen on purpose without pausing, hold **Control + Option** and push the cursor down against that screen's bottom edge.

## Troubleshooting

**The Dock still jumps.** Check that the menu bar icon is a closed lock. If the menu says it needs permission, click that line and turn DockKeeper on in the Accessibility list. If it is already on but still not working, remove it from the list with the minus button, add it again, and restart DockKeeper.

**"DockKeeper Not Opened: Apple could not verify..."** This is macOS blocking an app that is not signed with a paid Apple developer certificate. It is separate from the Accessibility permission. Click **Done**, then pick one fix:

- Easiest: paste this into Terminal (assumes the app is in Applications):

  ```sh
  xattr -dr com.apple.quarantine /Applications/DockKeeper.app && open /Applications/DockKeeper.app
  ```

- Or: go to **System Settings > Privacy & Security**, scroll all the way to the bottom (below the permission list), click **Open Anyway** next to the DockKeeper message, enter your password, and click **Open Anyway** again.

**"Open Anyway" does not appear.** Try opening the app once first, then look in Privacy & Security again. The button only shows up after macOS has blocked the app at least once. The Terminal command above always works.

**The Dock is already on the wrong screen.** Pause DockKeeper, move the cursor to the bottom of the screen with the menu bar until the Dock moves back, then turn Pause off.

**I want it gone.** Quit it from the menu, turn off Launch at Login first if you can, and delete the app. Remove it from the Accessibility list too.

## Notes and limits

- Built for **Apple Silicon** Macs running macOS 13 or later.
- Works with the Dock at the **bottom** of the screen. A Dock on the left or right side is not handled.
- The Dock stays on the display that has the menu bar. To change which display that is, drag the menu bar in **System Settings > Displays > Arrange**.
- Each rebuild or new version gets a new code signature, so macOS asks for Accessibility permission again. Remove the old DockKeeper entry and allow the new one.

## License

MIT. Free to use, copy, change, and share. See [LICENSE](LICENSE).
