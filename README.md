# SelectBar

An action bar over selected text for macOS. Select text in any application and
a capsule of icons appears next to the cursor: copy, search, translate, speak,
open a link. The app lives in the menu bar, with no window and no Dock icon.

Swift, AppKit and SwiftUI only, no third-party dependencies. Tested on a
MacBook Pro M3 Pro, macOS 26.

## The bar

It appears on mouse release if there is selected text at that spot. Which
buttons show depends on what is selected and on whether typing is allowed there:

| Applies to | When it shows |
|---|---|
| `Any text` | always, if something is selected |
| `Plain text` | text that looks like neither a link nor an email address |
| `Links only` | the selection looks like a link |
| `Emails only` | the selection looks like an email address |
| `Selected text you can edit` | a selection in a field that accepts typing |
| `Editable fields` | a double click in an empty input field |

The last row is the paste button: it appears on a double click in an empty field
and shows the start of the pasteboard contents right in its tooltip. A single
click does not summon the bar — that is just placing the caret.

An item can carry a length limit: speaking, for instance, is not offered for a
selection longer than 800 characters.

## Actions

The set holds **57 actions**, of which 7 are enabled. The rest wait in the
Actions tab and are switched on one at a time — otherwise the bar would grow to
a useless size.

**Built in.** Copy, cut, paste, open a link, write an email, search Google,
translate, speak aloud.

**Text transformations.** UPPERCASE and lowercase, Title Case, sentence case,
collapse spaces, remove spaces, sort lines, reverse lines, join lines, quotes,
comment, slug, URL encoding, Base64. All of them replace the selection, so they
only show where typing is allowed.

**Search and sites.** DuckDuckGo, Wikipedia, YouTube, images, maps, GitHub,
Stack Overflow, ChatGPT, Claude, IMDb, Spotify, Amazon, Reddit, Google Scholar,
LinkedIn, Messages.

**Dictionaries.** The system Dictionary through `dict://` (the "Apple
Dictionary" item), Thesaurus, Wiktionary, Urban Dictionary, Cambridge.

**Translators.** The built-in one through the DeepL desktop app, plus the web
versions of DeepL, Google, Yandex, Reverso and Bing.

**Notes and tasks.** Notes and Reminders through `osascript`, plus Things,
Todoist, Bear and Obsidian through their URL schemes. The last four open nothing
without the app installed.

**Saving links.** Raindrop and Instapaper — links only.

### Your own actions

Besides the built-ins there are two kinds, both configured in the Actions tab:

- **Open a URL** from a template where `{text}` is replaced by the selected text,
  percent-encoded;
- **Run a shell command**: `{text}` is substituted inside single quotes, and the
  text is also available in the `SB_TEXT` environment variable — handier when
  quotes inside it would get in the way.

## Appearance

Configured in the General tab:

- **size** — from 70% to 180%;
- **background style** — Solid, Glass, Glass (clear), Blur;
- **theme** — system, light or dark, independent of the system;
- **tint** — any colour with adjustable opacity.

The shape is always a capsule: the radius is half the height, so the proportions
hold at any scale. The bar is placed at the cursor rather than over the
selection — that way it is always where the eye is and does not jump across the
screen after a long selection.

## Menu bar

The icon can be hidden; getting back to settings then means relaunching the app
from Finder.

**Left click** opens settings right under the icon. **Right click** opens the
menu:

- **Restart** — relaunch (⌘R);
- **Open Accessibility Settings** — appears only while access is not granted;
- **Quit** (⌘Q).

## Keyboard backlight

The keyboard blinks on **incoming notifications** — from mail, messengers,
anything.

## Settings without a window

Two settings are not exposed in the interface and are changed by command:

```bash
defaults write local.selectbar blinkOnNotification -bool false   # blink on notifications
defaults write local.selectbar offerPaste -bool false            # the paste button
```

## How it works

A few places where the obvious solution does not.

**The selection is read by three routes in turn.** Plain `AXSelectedText` is not
enough everywhere. In applications with web views — Mail, Quick Look — it does
not exist, and `AXStringForTextMarkerRange` does the job. Terminal advertises the
attribute but returns an empty string for it: the real text is fetched by range
through `AXStringForRange`. If none of that helps, the focused element's subtree
is walked, then its window's.

**There is deliberately no synthetic ⌘C**, though many tools do exactly that. In
Finder it would copy the selected files instead of text. The price of refusing is
honest: applications that do not expose their selection through Accessibility
show no bar at all.

**The bar never takes focus** — a `nonactivatingPanel` with `canBecomeKey`
overridden. Otherwise the application beneath would drop the selection and we
would show buttons for text that no longer exists.

**Chrome had to be asked twice.** It keeps Accessibility off for speed and turns
it on when an assistive tool asks. `AXManualAccessibility` used to be that ask,
but Chrome now rejects it — measurement returned code -25205, "attribute not
supported", and the app stopped building its content tree entirely. The older and
more general `AXEnhancedUserInterface`, the one VoiceOver uses, is now set
alongside it.

**The glass style is built differently from the rest.** Group capsules live in an
`NSGlassEffectContainerView`, which fuses nearby glass shapes into one flowing
form the way system toolbars do. The buttons sit **not inside the glass** but as
a layer above it: inside, clicks never reached them. The capsule's area carries a
fill at 0.02 opacity — the panel's window is transparent, and without it macOS
would pass clicks through to the window below everywhere except the icon strokes
themselves. Glass adaptation to the background is switched off, or the panel
turned pale over a light background and its light icons vanished.

**Only the solid fill gets a shadow.** Glass casts its own and a second one lays
a double outline over it; with blur the window shadow rimmed the capsule
visibly.

**A double click no longer shows the bar twice.** Mouse-down is tracked
alongside mouse-up: the distance between them shows whether the mouse was
dragged or clicked in place. A drag keeps the old 0.12 s delay, a click waits
0.3 s so the showing can be cancelled when the second click arrives.

**Notifications are caught through the system log.** Subscribing through
Accessibility to windows of the notification centre process does not work: that
only catches the panel opened by clicking the clock, while a banner creates
neither a window nor an element. For every delivered notification the `usernoted`
service writes a line containing `NotificationRecord app:"…"`, and that is what
`log stream` reads. Orphaned reader processes are reaped at startup: on a crash
the exit handler never runs and they would accumulate.

**The keyboard backlight** goes through the private `CoreBrightness` framework,
loaded dynamically. There is no public interface; the methods were found by
enumerating them through the runtime.

## Building

```bash
./build.sh && open /Applications/SelectBar.app
```

The bundle is staged in a temporary folder outside iCloud sync. This is not
fussiness: the file provider stamps files with attributes `codesign` rejects, and
they come straight back if cleaned in place. The finished app is copied both into
the project folder and into `/Applications`.

The Xcode project is generated from `project.yml` with `xcodegen generate` and is
not part of the repository.

The signature matters not for security but because macOS ties granted permissions
to it; without one, access would have to be granted again after every rebuild.

## Permissions

**Accessibility** is required — without it the selection cannot be read. The app
waits for it in the background and starts working the moment it is granted.

**Automation** is asked for by the system itself the first time the "Notes" and
"Reminder" actions are used — they work through `osascript`.

The app cannot run sandboxed, so there is no route to the Mac App Store for it.

## Limits

The bar appears where an application exposes its selection through Accessibility.
Live text in images is not supported. The selection is caught on mouse release —
there is no way to summon the bar from the keyboard.

The built-in translation through the DeepL desktop app relies on a double ⌘C and
therefore depends on how copying behaves in the source application: in Terminal,
for one, it does not fire. The web translators do not share that flaw, since they
use the text that has already been read.
