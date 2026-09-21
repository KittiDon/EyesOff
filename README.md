# EyesOff

A tiny macOS menu bar app that blacks out your screen instantly, and brings it
back exactly as it was on your next click.

Useful when someone walks past your desk.

![menu bar icon](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)

## What it does

Click the eyes in the menu bar and the screen goes black. Click anywhere (or
press a key) and everything comes back — nothing is closed, minimized or
refocused, and there is no password prompt.

**Real black, not grey.** A black window on its own still leaves the LCD
backlight running, which reads as dark grey. EyesOff also drops the backlight to
zero and restores your exact previous level afterwards.

**Movement doesn't wake it.** Only a deliberate click or keypress brings the
screen back, so a nudged mouse or a brushed trackpad won't give you away. This
is enforced both in the event monitor mask and in the wake handler.

## Install

```sh
git clone https://github.com/KittiDon/EyesOff.git
cd EyesOff
./build.sh
open ~/Applications/EyesOff.app
```

`build.sh` compiles with `swiftc`, assembles the `.app` bundle and ad-hoc signs
it. No Xcode project, no dependencies.

To start it automatically, right-click the icon and tick **Open at Login**.

## Menu

Right-click the icon for:

| Item | |
|---|---|
| **Black Out Screen** | same as a left click |
| **Also Turn Off Backlight** | on by default; turn off to use a black window only |
| **Open at Login** | registers via `SMAppService` |
| **Quit EyesOff** | restores brightness first |

## Not getting stranded in the dark

Turning the backlight off is the part worth being careful about, so the
brightness you had is written to disk *before* dimming, and restored:

- on any wake, quit, sleep or shutdown
- on `SIGTERM`/`SIGINT`/`SIGHUP`
- on a fatal signal (`SIGSEGV`, `SIGABRT`, `SIGILL`, `SIGBUS`, `SIGFPE`,
  `SIGTRAP`) or an uncaught exception, via a handler that reads the stash back
- at the next launch, if the app died before any of the above could run

It also refuses to enter the blanked state if it can't create a cover window, so
there is never a black screen with nothing to click.

## Self-test

```sh
EYESOFF_SELFTEST=1 ~/Applications/EyesOff.app/Contents/MacOS/EyesOff
```

Blanks the screen, asserts the cover windows and backlight state, feeds
movement and drag events to confirm they are ignored, feeds a click to confirm
it wakes, and checks the brightness round-trips and the stash is cleared.

## How the backlight is controlled

Through `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness`, with
`CoreDisplay_Display_{Get,Set}UserBrightness` as a fallback. Both are private
API, so every call is guarded, and a display whose current brightness can't be
read is never dimmed — that way there is always a value to restore.

Built and tested on an Intel MacBook Air running macOS 15.

## Licence

MIT
