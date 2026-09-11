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
and shows the start of the pasteboard contents right in its tooltip.

A plain single click never summons the bar, and is not even looked into. It
cannot have made a selection — a word takes two clicks, a line or a paragraph
three, a run of text a drag — so there is nothing to ask Accessibility about.
Asking anyway did harm: a selection made in one window stays there and goes on
being reported, while a click elsewhere in the same application changes no
focus anyone is told about, and the bar came back over text the pointer had
long left. Shift-clicking is the exception and is looked into: it extends a
selection that already exists, and arrives as a single click like any other.

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
- **background style** — Solid, Glass, Glass (clear), Blur, Lens;
- **refraction** — twenty-three of them. Six are the system's own manoeuvre
  with different numbers (System, Deep, Sharp, Dome, Frost, Flat) and reach
  both the glass styles and the lens. The other seventeen are shapes of glass —
  Convex, Concave, Fisheye, Cylinder, Prism, Reduce, Magnify, Bevel, Ripple,
  Anamorphic, Fisheye prism, and six named for the elements they imitate:
  Fresnel, the lighthouse lens, its curve cut into rings and laid flat;
  Lenticular, a row of glass rods; Axicon, a cone rather than a dome, gathering
  light in a ring; Aspheric, nearly flat in the middle and sharp at the rim;
  Astigmatic, one power across and another down; and Coma, the comet-shaped
  smear given to whatever is off the axis. Only the Lens style draws these, the
  private filter having no notion of them;
- **theme** — system, light, dark, or **Auto**, which reads what the bar is
  about to cover and takes the same side: dark over a dark page, light over a
  light one. That reading needs Screen Recording, and without it Auto falls
  back to the system's setting;
- **tint** — any colour with adjustable opacity.

The shape is always a capsule: the radius is half the height, so the
proportions hold at any scale. The bar is placed at the cursor rather than over the
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

**The refraction setting rewrites a private filter rather than capturing the
screen.** How much glass bends what lies behind it is not exposed by AppKit at
all — `NSGlassEffectView` offers a style and a corner radius. Take one apart at
runtime and the machinery shows:

    CABackdropLayer          filter: glassBackground
      CASDFLayer             effect, gaussianRadius, smoothness, mergeElements
        CASDFElementLayer    contentsZeroValueDistance, gradientOvalization
    CASDFLayer               filter: vibrantColorMatrix
    SDFPortalLayer           sourceLayer, sourceContextId

`CABackdropLayer` is the layer that asks the window server for whatever sits
behind the window — which is why the system's glass needs no permission and
lights no indicator: the pixels never leave the compositor. The shape is a
signed distance field, and the bend is computed from the distance to the edge.

`CAFilter` turns out to publish its inputs. `filterTypes()` lists 43 named
filters — among them `displacementMap`, `chromaticAberration`, `variableBlur`
and `glassBackground` — and `glassBackground` takes some fifty of them:

    inputInnerRefractionAmount   inputInnerRefractionHeight
    inputOuterRefractionAmount   inputOuterRefractionHeight
    inputRefractionDistance0/1   inputRefractionOpacity
    inputBlurRadius              inputFaceOpacity        inputBleedAmount

A stock clear bar comes with an inner amount of −60 over a height of 20. The
settings are those numbers with different values — see `BarLens`. Deep spreads
the bend across the whole cap at −400, Sharp packs −260 into a band of 10, Flat
sets the amount to zero and leaves a plain translucent plate.

The eleven shapes beyond those six are not amounts at all. A fisheye is radial,
a cylinder works in one axis, a prism splits the channels apart, and Reduce
reads three and a half bar-widths across to shrink a paragraph into the bar —
none of which any pair of numbers in that filter can express. They live in the
shader, and the glass styles take the nearest approximation the filter can
manage. Reading wider than the bar is also why the photograph is taken four
times its size: cut to the bar, the sampler repeats the edge column, which is
what the stronger settings used to smear across their caps.

Two details make it work. The filter does not exist until the glass has drawn
itself once, and the system fills it in then, overwriting anything written
earlier — so the write is deferred and repeated across the first half-second.
And Core Animation hands the filter to the render tree when it is attached:
mutating it in place changes nothing on screen, the layer's `filters` array has
to be reassigned, with `disableFilterCache` set, before the new numbers are
drawn.

Both the filter's name and its input names are private and may vanish in any
macOS release. Every step is checked before use — an input that does not read
back is skipped — and if the shape of it ever stops matching, the bar keeps
exactly the look the system gave it.

**The Lens style is that discarded route, kept as an option.** It films the
screen behind the bar through ScreenCaptureKit and bends the picture in a Metal
shader. It began as one still taken when the bar appeared, on the reasoning
that nothing moves underneath in the second or two it is up. That is wrong
often enough to matter — video plays, pages scroll — and the lens sat showing a
moment that had passed, so it is an `SCStream` at thirty frames a second, alive
only while the bar is. The frames arrive as `CVPixelBuffer`s and reach the
shader through a `CVMetalTextureCache` without being copied; repeating single
screenshots on a timer would cost far more, each one enumerating the shareable
content of the whole machine before it could begin. The capsule is a signed
distance field there too, and the bend is that field's gradient applied to the
coordinate the picture is sampled at, falling off to nothing a band's width in.
The Refraction setting drives both routes: the same numbers go into the private
filter for glass and into the shader for the lens. The shader is compiled at
runtime rather than shipped as a `.metallib` — the build is one call to
`swiftc`, and adding a Metal step for eighty lines would be the larger change.

**The camera is told to stop, not left to be freed.** Ordering a panel out
does not take its content view off the window, and the window itself outlives
the call — measured: it and its views are still there after the autorelease
pool drains, and go about a second later, when the run loop gets to them. The
lens filmed for all of it, so the bar vanished and the recording indicator in
the menu bar stayed lit with nothing on screen to account for it. Hiding the
bar now stops the stream outright.

That indicator cannot be dismissed, and nothing here tries. It is the system's
own, drawn where no application can reach, and it is lit exactly as long as
something is capturing. What can be done is to capture for less time — which is
also why the preview in settings films for a couple of seconds and then holds
its last frame, rather than running for as long as the Appearance page is open.

**The bar keeps itself out of its own film.** Not by the capture filter, which
excludes this application by asking for the list of applications with windows
on screen — a list the bar's panel is not in yet the first time round, because
it is still being assembled. The exclusion came out empty and the lens filmed
itself, folding its own picture in over and over. Every window the app puts on
screen is instead marked `sharingType = .none`, which the window server obeys
without anyone having to enumerate anything.

A stream also takes a moment to start, and may never start at all — the
permission refused, or granted just now and not in force until the next launch.
The lens draws nothing until its first frame. A plain fill was tried there, so
that a lens which could not film would at least look like the Solid style, and
taken out again: the moment before the first frame is the moment the bar is
appearing, and a plate flashing and then giving way to the picture is worse
than nothing at all for that instant.

The conversion from the filter's amounts to pixels is fitted by eye against a
rendering of the shader, not derived: `amount` is not a distance. Two things
came out of looking at that rendering rather than reasoning about it — a
highlight tied to the refraction band washed out the whole capsule, the band
being 20 points against a bar of 38; and a sixth of the amount put 133 pixels
of displacement on a bar 38 tall. The rim is now a fixed four pixels and the
displacement is capped just under the band.

**Reading the screen was tried first and made an option rather than the default.** A Metal shader can bend
anything, but it only ever sees its own application's content: it cannot reach
into another app's window, and the shader route therefore needs a screenshot of
what is behind the bar. That works — ScreenCaptureKit at 30 frames a second,
our own app excluded from the capture — and it costs a Screen Recording
permission and a purple indicator sitting in the menu bar the whole time the
bar is up. Rewriting the system's own filter gives the same control over the
bend with neither.

**Glass cannot be faded.** Setting any alpha below 1 on it forces the view
through an intermediate composite, and the system then drops the effect
altogether: the bar comes out a plain plate with no glass in it. So the opacity
setting is disabled for both glass styles, which carry their own translucency
through their style instead.

**The bar sits above everything, Picture in Picture included.** It was at
level 3 for a long time — above ordinary windows, below the Dock, the menu bar
and Control Centre — on the reasoning that a bar covering those is worse than
one hiding behind them. But Picture in Picture floats higher than 3, as do
other always-on-top windows, and the bar went under them: summoned over a
selection and then invisible. It is at the screen saver's level now, above all
of it. What it covers, it covers for a moment — it appears at the cursor and
any click at all takes it away.

**Only the solid fill gets a shadow.** Glass casts its own and a second one lays
a double outline over it; with blur the window shadow rimmed the capsule
visibly.

**A double click no longer shows the bar twice.** Mouse-down is tracked
alongside mouse-up: the distance between them shows whether the mouse was
dragged or clicked in place. A drag keeps the old 0.12 s delay, a click waits
0.3 s so the showing can be cancelled when the second click arrives.

**The log is only read while there is a reason to.** Noticing notifications
means a `log stream` of our own — a whole child process, alive as long as the
app is. It used to start unconditionally and consult the setting afterwards, in
the handler, so switching the blinking off still paid for the process that
existed to call that handler, and a machine with no keyboard backlight paid for
it while never being able to get anything back. Measured, the process and its
4.5 MB simply go.

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
