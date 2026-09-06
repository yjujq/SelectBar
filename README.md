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
Actions page and are switched on one at a time — otherwise the bar would grow to
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
versions of DeepL, Google, Reverso and Bing.

**Notes and tasks.** Notes and Reminders through `osascript`, plus Things,
Todoist, Bear and Obsidian through their URL schemes. The last four open nothing
without the app installed.

**Saving links.** Raindrop and Instapaper — links only.

### Labels

Each item chooses on its own what the bar shows for it: **the icon**, **the icon
and its title**, or **the title alone**. The setting sits on each item’s page under Actions
beside the title and the symbol, and every item starts on the icon.

It is deliberately per item rather than one switch for all. A labelled button is
as wide as its content — "Translate" with its icon runs to about 110 pt at the
default scale — so labelling all seven enabled items would stretch the bar past
600 pt. Labelled one at a time, only the items whose glyph is hard to read need
the words.

An item whose symbol name is unknown shows its title whatever it asks for:
there would otherwise be nothing to show at all.

### Your own actions

Besides the built-ins there are two kinds, both configured on the Actions page:

- **Open a URL** from a template where `{text}` is replaced by the selected text,
  percent-encoded;
- **Run a shell command**: `{text}` is substituted inside single quotes, and the
  text is also available in the `SB_TEXT` environment variable — handier when
  quotes inside it would get in the way.

## Appearance

Configured under Appearance:

- **size** — from 70% to 180%;
- **opacity** — from 30% to 100%, for the solid and blur styles. It reaches the
  background only: the backdrop and the buttons are siblings rather than
  nested, so the icons keep their full strength however faint the bar behind
  them. Glass is left out — see below;
- **background style** — Solid, Glass, Glass (clear), Blur;
- **theme** — system, light or dark, independent of the system;
- **tint** — any colour with adjustable opacity.

The shape is always a capsule: the radius is half the height, so the proportions
hold at any scale. The bar is placed at the cursor rather than over the
selection — that way it is always where the eye is and does not jump across the
screen after a long selection.

The button under the pointer lights up, so it is plain which one a click will
reach.

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

The blink is switched on and off under Behaviour.

## Settings without a window

One setting is not exposed in the interface and is changed by command:

```bash
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

**The hover highlight is a full-height pill** on the button's own layer
background, not a sublayer: a sublayer is drawn above the view's content and
would cover the icon. Its tracking area is registered `.activeAlways`, since
the panel never becomes key and an `.activeInKeyWindow` area would never fire.

The button row is clipped to the capsule's shape. It was first reasoned that no
clipping was needed, the pill being contained by construction — but measuring
the live view tree showed the buttons come out taller than the bar, 45 to 49
points against its 38, each sized by its own icon because the height constraint
loses to the stack's fixed frame. They hang over the edges. Nothing showed
while they were transparent; the pill is not.

**Password fields get no bar.** Accessibility hands back a row of bullets for a
secure field rather than its text, so the bar would have offered actions on
characters that do not exist — and nothing there can be copied in any case. The
sign is the subrole, `AXSecureTextField`; the role is a plain `AXTextField`,
the same as any other input.

That is as far as "hide the bar where copying is impossible" reaches. There is
no Accessibility attribute meaning "this can be copied". Reading the Edit ▸ Copy
item's enabled state is unreliable — an app's menu items are often not
populated until the menu is opened, and many leave Copy enabled regardless. And
it would rarely help: the bar reads the selection through Accessibility rather
than by copying, so its actions work even where ⌘C does not. Only the built-in
DeepL translation, which does send a double ⌘C, depends on copying.

**The bar never takes focus** — a `nonactivatingPanel` with `canBecomeKey`
overridden. Otherwise the application beneath would drop the selection and we
would show buttons for text that no longer exists.

**Chrome had to be asked twice.** It keeps Accessibility off for speed and turns
it on when an assistive tool asks. `AXManualAccessibility` used to be that ask,
but Chrome now rejects it — measurement returned code -25205, "attribute not
supported", and the app stopped building its content tree entirely. The older and
more general `AXEnhancedUserInterface`, the one VoiceOver uses, is now set
alongside it.

**The glass style is built differently from the rest.** A single capsule lives in
an `NSGlassEffectContainerView`, which is where a glass view belongs and what
draws the shadow and glow around it. The bar was once split by meaning —
built-ins, links, shell commands — into a capsule apiece with a gap between
them, left to the container to fuse. It did not read as one object: enabling an
action of a new kind grew the bar by a separate piece rather than lengthening
the one shape, and the split reordered the icons besides. The buttons sit **not
inside the glass** but as a layer above it: inside, clicks never reached them.
The capsule's area carries a fill at 0.02 opacity — the panel's window is
transparent, and without it macOS would pass clicks through to the window below
everywhere except the icon strokes themselves. Glass adaptation to the
background is switched off, or the panel turned pale over a light background and
its light icons vanished.

**Glass cannot be faded.** Setting any alpha below 1 on it forces the view
through an intermediate composite, and the system then drops the effect
altogether: the bar comes out a plain plate with no glass in it. So the opacity
setting is disabled for both glass styles, which carry their own translucency
through their style instead.

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

**A blink never starts on a dark keyboard.** The level is written with a commit,
so it is stored as the standing preference — and a blink that ends on zero pins
zero, leaving the light dead through every later wake. That is exactly what
happened after sleep: waking syncs mail, the notification arrives before the
system has restored the backlight, zero gets read as "the original" and
faithfully written back. A reading of zero is now left alone; there is no
telling it from a backlight the owner switched off, and both make blinking
wrong. The restore itself sits in a `defer` rather than after the loop, since
sleep suspends the task mid-blink and a plain trailing line simply never ran.

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
