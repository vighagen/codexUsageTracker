# Codex Usage Tracker

A floating smoky-quartz widget that shows the **remaining weekly Codex limit** inside the orb. Its faceted glass, champagne rim, and smoky wisps follow the supplied fantasy-orb reference.

![Codex Usage Tracker hover demo: smoke and inner shimmer animate on hover, then pause](docs/orb-hover.gif)

*Rendered from the app with example usage (77%): 2 seconds idle, a full 12-second hover cycle, then 2 seconds paused. [Still preview](docs/orb-hover.png).*

Double-click **Codex Usage Tracker.app** to launch it. Drag it to your preferred position on the desktop. Right-click the orb (or use its small menu-bar icon) to refresh, change its size or colour scheme, bring it back into view, or quit.

Hover over the orb to reveal two buttons: **New chat** (compose icon) and **Voice chat** (waveform icon). The smoke moves through a very slow 12-second cycle only while hovered, then pauses. A subtle shimmer inside the glass shares the same hover clock: both effects pause on exit and resume on re-entry. The percentage stays legible and does not shimmer. The animation respects macOS Reduce Motion.

While any local Codex task is working, the orb gently floats and a light travels around its rim, even without hovering. This motion stops when all observed tasks finish, fail, are cancelled, or wait for input/approval. Hover smoke and shimmer keep their separate 12-second timing. Reduce Motion disables movement.

![Working-state animation: the orb floats while AI is working, then stops](docs/orb-working.gif)

*Example working-state preview, rendered from the app. [Still preview](docs/orb-working.png).*

**New chat** uses the documented `codex://threads/new` link. **Voice chat** opens a new Codex chat and sends its documented **Control–Shift–V** shortcut only to the Codex process. This requires Accessibility permission for Codex Usage Tracker: the first click offers to open **System Settings → Privacy & Security → Accessibility**. Enable Codex Usage Tracker there, then click Voice chat again. If it is absent, use **+** to add this app. No permission is granted automatically. Codex handles any microphone/voice setup. If you have changed the voice shortcut in Codex, restore Control–Shift–V for this button.

References: [Codex deep links and keyboard shortcuts](https://learn.chatgpt.com/docs/reference/commands), [voice setup](https://learn.chatgpt.com/docs/features/voice).

- Refreshes every 60 seconds while running and when the Mac wakes.
- Calculates `100 − usedPercent` from the Codex quota window whose duration is 10,080 minutes. Supports the weekly limit in either the primary or secondary position.
- Uses the installed Codex CLI and your existing Codex sign-in through the documented [`account/rateLimits/read` API](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).
- Usage polling does not run model requests, spend reset credits, or read/store authentication tokens itself. Chat and voice start only from your button clicks.
- Shows a dash when the connection fails, no weekly limit is available, the data is over three minutes old, or the reported reset time has passed.
- Choose **Colour scheme → Deep red, Mint green, Teal, Ivory, Purple**, or **Original** in the right-click menu. The selection is remembered after restarting.
- Remembers its position and size. Floats across desktops.
- Runs until you quit it. Open the app again after restarting your Mac; it has not been added to Login Items.

The app is built locally for this Mac and signed with an ad-hoc signature. Source is included in `main.swift`, `WeeklyUsage.swift`, `OrbInteraction.swift`, and `ActivityMonitor.swift`. To rebuild, run `zsh build.sh` in this folder. The build also checks weekly-window selection, remaining-percentage calculation, unavailable data, freshness, hover/pause timing, smoke motion, and shimmer containment. Rendering checks need normal macOS graphics access.

The artwork was created using the built-in image generation tool. The transparent PNG is in `Assets/smoky-quartz.png`, and the exact generation prompt is in `Assets/design-prompt.txt`. The percentage is rendered live by the app; it is not part of the image.

## Build from source

Requires macOS 13 or later, Xcode Command Line Tools (`xcode-select --install`), and a signed-in Codex desktop app.

```sh
git clone https://github.com/vighagen/codexUsageTracker.git
cd codexUsageTracker
zsh build.sh
open "Codex Usage Tracker.app"
```

The build creates a locally signed app for your Mac and runs the included usage, hover-clock, smoke, shimmer, and colour checks. Core Image's runtime shader API currently produces deprecation warnings but is verified working on the development Mac.

A prebuilt macOS app archive is provided under `dist/`. It is ad-hoc signed, not notarized; building locally is the recommended installation route.

## Regenerate the preview

Run `python3 scripts/render-preview.py` on macOS to render the GIF and PNG from the production view and shader code. The preview uses a fixed example percentage and does not connect to your Codex account.

## Task activity detection

The widget reads the local Codex thread index and subscribes as an observer to the desktop app's local IPC stream. It never starts or resumes tasks, sends prompts, or handles approvals. Only runtime status, pending-request count, revision, and owner IDs are retained; conversation text and tool payloads are discarded. No activity data is sent off the Mac.

It follows all unarchived local tasks in the Codex thread index, including project tasks and subagents; there is no recent-task cap. Large tasks that omit their initial snapshot are also recognized from live reasoning/tool execution updates in their current streaming tail. One task finishing cannot stop the animation while another tracked task is working. New tasks are discovered every three seconds; completion and waiting updates arrive through the event stream. Remote/cloud-only tasks are not covered. The status meanings follow [Codex task runtime states](https://learn.chatgpt.com/docs/app-server#track-thread-status-changes), but the desktop IPC integration itself is internal and may need updating after a Codex release. If the connection is unavailable, the working animation stops and the tooltip reports activity unavailable. An unsupported stream is not counted, but other confirmed working tasks still keep the animation on. Temporary index-read failures preserve existing subscriptions. Oversized snapshots are scanned incrementally for activity status with bounded memory, so a large conversation cannot disconnect tracking for every task. Connecting an unrelated observer no longer requests every conversation snapshot again.

Run `python3 tests/activity_stream.py "Codex Usage Tracker.app/Contents/MacOS/CodexUsageTracker"` to test active, waiting, completed, and disconnected transitions against a local fixture server. Run `python3 scripts/render-preview.py --working` to regenerate the working-state GIF.

Regression check for concurrent tasks, older projects, and missing initial snapshots: `python3 tests/activity_multiple_tasks.py "Codex Usage Tracker.app/Contents/MacOS/CodexUsageTracker"`.

Account changes are automatic. Each usage refresh launches a fresh Codex reader so credentials from an earlier session are not reused. Changes to local sign in file metadata trigger an immediate refresh; other credential stores are picked up on the next refresh within one minute. The widget stores no account identity or credentials. Accounts without a weekly usage window show usage unavailable.
