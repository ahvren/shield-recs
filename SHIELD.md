# Viewing the page on the Shield TV Pro

URL: `http://<VM-IP>:8088/`. `deploy.sh` prints the exact URL when it finishes.

## Option A: Fully Kiosk Browser (recommended; full screen, opens apps)
1. Install **Fully Kiosk Browser** (`de.ozerov.fully`) from the Play Store on the Shield. Fully's docs say v1.61+ has the Android TV improvements.
2. Open it. On Android TV, **long-press Back** to open the menu.
3. Go to Settings > Web Content Settings > **Start URL**: `http://<VM-IP>:8088/`
4. In the same section, turn on **Open URL Schemes in Other Apps**. The page's "Open in Netflix / Prime / HBO Max / Disney+" buttons are Android `intent:` links, and Fully only hands those to apps with this setting on.
5. Fully runs full screen by default (toolbars are off). Optional: Kiosk Mode. Fully's TV FAQ notes that setting it as the home app often fails on Android TV and needs an app restart, or ADB `pm set-home-activity`. You already use Projectivy as home, so skip Kiosk Mode and just add Fully as a Projectivy tile. It opens straight to the start URL.

## Option B: TV Bro (free, open source)
Install **TV Bro** (`com.phlox.tvwebbrowser`). Open the URL, then use the menu to bookmark it and use its fullscreen mode. It's remote-friendly, but it has no start-URL kiosk setting, and I haven't verified that it hands `intent:` links to other apps. If the "Open in …" buttons don't work, use the "web page" buttons or the app itself.

## Remote controls on the page
- D-pad: move between tiles. Up and Down switch between the Movies and Shows rows.
- OK: open the details card for the tile.
- OK on **Open in <service>**: launch the app.
- Back: close the details card.

The page re-reads `recs.json` every 30 minutes, so new weekly picks appear without a reload.

## Confirm the app package names once (you have ADB)
`adb connect 192.168.50.21 && adb shell pm list packages | grep -E 'netflix|amazonvideo|wbd|hbo|disney'`
The page assumes `com.netflix.ninja`, `com.amazon.amazonvideo.livingroom`, `com.wbd.stream`, and `com.disney.disneyplus`. If any differ, edit `services.<name>.package` in `recs.json`. No HTML change is needed.
