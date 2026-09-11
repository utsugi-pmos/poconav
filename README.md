# PocoNav

Where you are, and how to drive to somewhere else.

It exists because **no map application on this phone is meant for a phone**: they
are desktop programs shoehorned into a six-inch screen. This one is made the other
way round — for a phone **in landscape**, clipped to the windscreen, read at a
glance.

---

## What it does

**The map**

- OSM full-screen, drag and pinch.
- Your position: a blue dot, and an oriented arrow when you are moving.
- **It tells you where that dot comes from.** If it is the GPS, in metres. If it is
  the network estimate, it says so and paints the dot amber.
- It stays stuck to you; if you drag the map it comes loose; the crosshair button
  sticks it back. It opens where you closed it.

**The route**

- Destination by **name search** or by **holding your finger** on any point of the
  map.
- Preview: the whole route framed, with kilometres, time and two big buttons —
  *Remove* and *Start*.
- Driving: **the manoeuvre coming up**, with its arrow, the metres remaining and the
  street. Below, what is left and the arrival time. And **Exit**.
- The map turns with your motion (north up when you are stopped), and you sit in the
  lower third to see what is coming.
- If you leave the route, it says so.

- **Saved**: the destinations you repeat are saved and appear on opening the search,
  with the distance they are at. They are saved from a search result or from the
  preview — meaning **a point on the map with no name can also be saved**, which is
  exactly the one you cannot search for again.
- **Avoid tolls** and **avoid motorways**, right there next to the destination,
  because they change the road it will give you.
- **Speed** in the panel, in km/h, from the GPS.
- **Lanes**: at junctions that have them, the strip says which one to take.
- **3D view** and **north / compass**, with their buttons on the initial screen.
- If you close with a route half-done, **on opening it keeps navigating** — as long
  as no more than a day has passed.

- **Voice** in Spanish, with the phrases the router itself writes.
- **Recalculates by itself** if you leave the route.

**It does not do:** on-foot or bike routes, nor choosing between several voices.

---

## The voice

The phrases **are not written by PocoNav**. Valhalla already returns three wordings
per manoeuvre, meant to be read aloud and without abbreviations:

| | |
|---|---|
| `verbal_transition_alert_instruction` | the alert from far off |
| `verbal_pre_transition_instruction` | just before, with the distance inside |
| `verbal_post_transition_instruction` | what comes next |

Composing them on our own would be rewriting worse what the router already does
well, and in the wrong language.

**Two announcements per manoeuvre**, and the distances go with the speed: at 120 km/h
350 m is ten seconds and arrives late; in town 900 m is three junctions early and you
would not know which one it means.

| | far off | on top |
|---|---|---|
| under 80 km/h | 350 m | 110 m |
| over 80 km/h | 900 m | 250 m |

Tested with the `mock` engine, which runs all the logic without emitting sound: it
stays quiet above 350 m, warns **once** on crossing it, repeats it on crossing 110 m,
and **does not speak again** about that manoeuvre. On changing manoeuvre, again.

A new instruction **cuts** whatever was sounding instead of queuing: a queue ends up
talking about a junction you have already passed.

### Where the voice comes from

`qt6-qtspeech` already ships with Plasma, but out of the box it only brings the
`flite` engine. Measured: `availableLocales()` returns **exactly `en_US`**, and five
voices, all five English. There is no way out that way.

**Today Piper speaks**, with a neural-network voice, and the model is downloaded from
the application's own settings. This section used to say the opposite —that Piper was
ruled out because its models have to be downloaded from outside the repositories— and
that remains **the only documented exception** to the project's rule: it was accepted
because it is the difference between a voice that sounds like a person and one that
sounds like a robot, and because the download is done by the application, at the
user's request, not by the installer behind their back.

`espeak-ng` stays as fallback: if there is no downloaded model, it speaks. Ugly, but
understandable, and better than silence.

With neither of the two the application **stays quiet on purpose** and the voice
button comes out off. An English voice reading «Calle Bergantil» is worse than
nothing.

The voice button is **among the map buttons, not in the panel** — so the driving
panel still has a single button, and silencing it can be done without thinking.

---

## Recalculating on leaving the route

It does not recalculate at the first metre off: a GPS with poor accuracy leaves and
comes back on its own, and recalculating over that sends you somewhere else for no
reason. It takes **eight seconds straight** at more than 60 m from the line.

And with a handbrake: **25 s minimum between recalculations**. Without that, a
badly-mapped stretch leaves the application asking a public server for routes in a
loop, which is the way to get blocked.

On recalculating it says so aloud and forgets what it had already announced, because
the new route starts over from its first manoeuvre.

---

## The lanes come from a second router

Measured: **Valhalla 3.8.3 does not return lanes**. Not one, across three routes and
41 manoeuvres, including the M-30 and the Gran Vía. **OSRM does**, as
`intersections[].lanes`, with `valid` (whether that lane serves you) and `indications`
(which way it lets you go).

So the text comes from Valhalla, in Spanish, and the lanes from OSRM. Two requests per
route, both to FOSSGIS servers.

The two routers may not take the same road, so **the lanes are matched to Valhalla's
manoeuvre by proximity, never by index**: if an OSRM junction does not fall within
30 m of a manoeuvre, it is discarded. If the routes diverge, nothing is matched and
nothing is shown. **An invented lane at a junction is worse than no lane**, and that is
why it fails safe.

The lane request goes out **after** the route is taken as good: if the second server
is slow or fails, the route is already on screen and no one notices.

In the strip, the lane that serves you goes solid and the one that does not, dimmed
**but still present**: you need to see that there are four lanes and that yours is the
second, and a strip with the useless ones erased would count wrong.

---

## North, compass and 3D

Two buttons on the initial screen:

- **Compass** — north up, or the map turning with the phone. Today it comes out
  **off**: the only IIO devices on this phone are the PMIC's ADCs, there is no
  magnetometer or accelerometer, and `iio-sensor-proxy` does not even start.
  QtSensors instantiates without complaint and says `connectedToBackend = false`,
  which is the honest signal that governs the button. **The day the sensor appears,
  it turns on by itself and nothing needs touching.**
- **3D / 2D** — tilts the map camera. Measured: `maximumTilt` is 80; 50 is used, which
  is as far as you can go before the horizon eats half the screen.

While driving, the heading of motion overrides both.

---

## The look: Google Maps', on purpose

The colours and shapes are copied from Google Maps' driving mode in Android Auto, and
not for lack of ideas: **it is the navigation interface most drivers already carry in
their heads**. The blue card means "the instruction", the time in green means "when
you arrive" and the white circle with the blue glyph means "map button" *before*
anyone reads a word. Copying a visual language the driver already has learned is worth
more than any originality here.

All that lives in **[`Theme.qml`](Theme.qml)**: one file, and the whole application
follows it.

| | |
|---|---|
| `#1a73e8` | the manoeuvre card, the *Start* button, the centre button when it is stuck to you |
| `#4285f4` / `#1558b0` | the route: light core over a dark casing |
| `#34a853` | the arrival time |
| `#f9ab00` | the position that is an estimate, and leaving the route |
| `#202124` / `#303134` | the surfaces |

**It does not follow the desktop theme.** A navigator has to look the same at noon as
at midnight, and a white panel on the windscreen at night is a lamp pointed at the
driver.

---

## The driving screen

Everything on that screen obeys the same rule: **it reads at a glance or it is
useless**. It is two blocks, in both orientations:

- The **blue card**: what you are going to do — arrow, metres and street.
- The **dark strip**: what is left — arrival time in green, time and distance, speed,
  and *Exit*.

In landscape the card is a column on the left; in portrait it is a band at the top.
It is the same information, not a cut-down version.

- The **metres remaining** are the biggest thing on the screen. The street comes
  after. The whole phrase goes last, because no one finishes it while driving.
- **Exit is the only button on the panel.** Nothing else there can be pressed by
  mistake.
- You sit **centred horizontally in the map column and a little below its middle**
  (66 %), so that most of the screen is the road ahead and not the one you have
  already passed.
- The zoom buttons disappear and the centre one dims —but only a little: at 0.55 the
  blue washed out so much that it stopped reading as a button.

### The arrows are drawn, not borrowed

Breeze **has no manoeuvre arrows**. Everything that looked usable —`arrow-up`,
`go-up`, `draw-arrow-up`, `arrow-up-double`— is a thin chevron, and a chevron turned
90° reads as a bracket, not as "turn left". Placed side by side at 96 px none of them
worked.

That is why `ManeuverArrow.qml` paints them with a `Canvas`: shaft, rounded elbow and
solid tip. The tight ones raise the elbow, or the tip collides with its own shaft. The
U-turn carries a real semicircle, because with two straight lines it would fold over
itself.

At roundabouts **the exit number goes inside the ring**, which is what you look at. The
exit arrow goes at a fixed angle on purpose: Valhalla gives the number but **not** the
heading, and inventing the angle would be worse than not putting it.

---

## Why Valhalla and not Qt's router

QtLocation brings its own routing, and it works: same road, same distance. But **Qt
writes the manoeuvres itself, in English**, and along the way loses what the driver
needs. Measured over the same pair of points, Bolnuevo → Mazarrón:

| | |
|---|---|
| **Qt / OSRM** | `Enter the roundabout and take the second exit` + `exit roundabout to/onto  ` — two steps for a roundabout, and without the name |
| **Valhalla** | `Haga la roundabout y tome la output 3.º toward RM-D6.` |

The server writes, so **the language is a parameter** and the exit number comes inside.
Qt's parser can do neither of those two things.

What it costs: the HTTP request, the decoding of the polyline and advancing along the
route are ours. That is `Route.qml`.

**Servers**, FOSSGIS's public ones, with no account or key:

| | |
|---|---|
| Tiles | `tile.openstreetmap.org` |
| Routes | `valhalla1.openstreetmap.de` |
| Search | `nominatim.openstreetmap.org` |

All three ask for an identifiable User-Agent and moderate use, and all three have it.
**Nominatim forbids searching while you type** —*"you must not implement such a service
on the client side using the API"*—, so against its server you have to type and press.

But **with the region downloaded it does search live**, with a 0.8 s debounce: it waits
for you to stop typing and then queries. Typing «cartagena» is nine keystrokes and a
single query; verified in the self-test typing letter by letter faster than the clock.

There there is no policy to respect: the base is ours, it is on the phone, and a search
takes between 5 and 30 ms over all of Spain. The list is cleared **on receiving** the
response and not on requesting it, because emptying it while it arrives leaves it blank
for an instant at each pause, and that flicker is what makes a live search feel broken.

---

## Why it stopped being pure QML

For almost all of its development it was **pure QML**, run by `qmlscene` without
compiling anything. It started as a good decision: the application only painted a map,
and not compiling meant no `APKBUILD`, no cross-compilation, no binary to maintain.

It stopped being one without it showing. QML cannot write a file, launch a process, or
talk to logind — so **every new feature arrived crippled**, and each cripple was
patched over with a shell script on the outside:

| What was needed | The workaround |
|---|---|
| Say a phrase over the speaker | The application wrote the phrase into its settings file and a script read it **every 0.3 s** |
| Not turn off the screen while driving | Another poll of the same file, every five seconds |
| Download maps | A separate script, run by hand, that the application did not know existed |

The three workarounds were the price of a design decision, not a limit of Qt. And the
third was the one that made it depend on **osmscout-server** for what it should not
have depended on anyone: if the application has nowhere to put the code that downloads,
someone from outside has to download.

So now there is a C++ backend (`src/backend.cpp`) and the application is a real
package. The QML barely changed: where it wrote to the settings file, it now calls
`app.speak(...)` or `app.downloadMap(...)`.

What was gained, besides the features:

- **`qmlscene` is deprecated** and Qt warned about it on every start.
- **The icon no longer needs a trick.** The window presented itself as
  `org.qt-project.qmlscene`, and the launcher had to declare exactly that for Plasma to
  recognise it. Now the `StartupWMClass` is `poconav`, as it should be.
- **No more polls.** Nothing reads a file in a loop waiting for it to change.

What it cost: it has to be compiled. `surya/pmaports/sincronizar` copies the sources
next to the recipe and recomputes the sums; `pmbootstrap build poconav` does the rest.

---

## The screen, while you drive

A screen that turns off midway leaves the phone useless right when it is needed. And
the dumb solution —not letting it turn off while the application is open— is worse: you
leave the map open in your pocket and arrive with no battery.

So the lock **comes and goes with the navigation**: on entering drive mode the QML
calls `app.keepScreenOn(true)` and the backend raises a `systemd-inhibit
--what=idle`, which is what PowerDevil looks at to turn off the screen by itself. On
leaving, it releases it.

`sleep` is not requested: if you press the power button, let it turn off, that is what
you press it for.

---

## Testing it without a car and without looking at the phone

Two modes of the binary itself and one button, and all three exist because that is
exactly what I was missing.

### `--test`: the self-test

It loads the **same** `Route.qml` against the **same** backend and asks for real
routes: one on the phone, another over the internet, the planner with filters, the
search without network, and **the Bolnuevo → Murcia trip travelled point by point**. It
exits with a nonzero code if anything fails.

It was born from a specific fault: I tested the server by hand from Python with POST,
the piece worked, and the application asks via `GET ?json=`. It got a 404 on every
route. **The piece worked, the path did not** — and the path is the only thing that
matters to whoever drives.

What it has found since then, all on its first run:

| | |
|---|---|
| Valhalla's `Actor` **is not thread-safe** | Two requests at once took down the server with a SEGV inside the library |
| `piper` and `aplay` stayed alive on close | After the `kill()` no one waited for them to die |
| The lane and limit handlers wrote over the **already destroyed** route | They arrive later than the route, so the window is real |
| **The trip was never given as finished** | See below |

### The **Simulate** button

A pretend car travels the chosen route and the application behaves as if it were being
driven. At the speed each stretch **allows**, not a fixed one: the route already brings
the legal limit point by point, so it speeds up on the motorway and brakes on entering
the town. With a constant 50 km/h, warnings that arrive late on a motorway would be
taken as good.

With the phone on the table the GPS always gives the same point, so **half the
application — precisely the half that matters while driving — there was no way to see**.

To make it possible, where the position comes from had to be gathered in one place. It
was spread across twenty reads of `gps.position`; now there is `root.coord`,
`root.speed` and `root.headingSource`. With the twenty loose, simulating would have
been patching seventeen and forgetting three.

**And it found the fault on the first try.** Travelling the whole route, the application
reached the last point and kept saying **91 metres** remained. Since arrival requires
less than 25, the trip never finished: neither the navigation closes, nor the saved
route is cleared, nor the screen released.

The cause: `totalMeters` came from `summary.length` —what Valhalla says, taken from the
graph edges— but progress is measured over the decoded polyline. Two measurements of
the same route: 77.40 km and 77.31 km. That difference stayed always left to travel.

### `--portraits <folder>`: the application photographs itself

Eleven screens —home, search, settings, routes, alert and drive, in both orientations—
painted in memory with `QT_QPA_PLATFORM=offscreen` and saved with `grabToImage`.

The compositor's capture **does not work**: with the session locked KWin returns a
blank image on purpose, and I was taking as good files of 10 kB all identical without a
single clue. This needs no screen, no unlocking, no having the phone at hand, and they
come out **always the same**, which is what lets you compare a change of margins with
what came before.

The `canvas` is photographed and not the window: a window's `contentItem` is built by
C++ and `grabToImage` rejects it with *"item has no QML engine"*.

**The first thing it showed**: the map buttons came out as empty circles.

```
QIcon::themeSearchPaths()   →  ":/icons"
QIcon::hasThemeIcon("gps")  →  false
```

Only Qt's internal resource. `/usr/share/icons` was not there, because those paths come
from `XDG_DATA_DIRS` and starting without a full desktop session that variable comes
empty.

---

## QML traps that cost a batch each

- **An anchor set to `undefined` is NOT removed.** `anchors.bottom: landscape ?
  parent.bottom : undefined` leaves the anchor set forever as soon as it evaluates once
  to `parent.bottom`. On turning to portrait, the panel stayed full-screen and the map
  measured `540x0`. The panel's geometry and the map's are computed by hand, without
  anchors.
- **A signal handler can run before a binding that depends on the same thing.**
  `frameRoute()` started with `if (!route.exists) return`, and called from
  `onStatusChanged` `exists` was still `false`: the framing was done *never* and half the
  route stayed off screen, without a single error. Now it looks at the array directly.
- **GPS tracking undoes any framing.** On entering the preview you have to release the
  tracking, or the next fix recentres the map on you and throws the framing in the bin.

And one from GeoClue: **it gives speeds of a couple of m/s with the phone still on a
table.** With the threshold at walking pace, the map turned to some heading or other
and —since the heading is never reset, on purpose— it stayed that way. The threshold is
at 2.8 m/s, i.e. 10 km/h.

---

## Decisions about the tiles

**Where they come from.** Qt asks `maps-redirect.qt.io` which servers to use. When that
service is slow or down, the map comes out **blank and with no error anywhere**. It is
disabled (`providersrepository.disabled`) and `tile.openstreetmap.org` is set by hand.

**How many are requested.** Measured: with the default value Qt prefetches two
neighbouring zoom levels, i.e. **hundreds of tiles at once** over a single HTTP/2
connection. `tile.openstreetmap.org` responds `ENHANCE_YOUR_CALM` —«excessive load
detected»— and drops them all; the map stays grey. With `NoPrefetching` only what is
seen is requested. It is not performance: **meeting the usage policy is a condition for
using the public servers**.

**The attribution.** Qt's apparatus comes out empty with a custom tile server: it draws
a white strip at the bottom and no text. It is turned off and painted by hand, and in
the preview it **rises above the bar** instead of hiding behind it, because it is a
condition of the licence and not an ornament to remove when it gets in the way.

---

## Offline: what it is and what it is not

It is worth being exact, because "offline" promises more than there is.

**The order is: the internet rules, and the phone answers when there is none.**

It was the other way round, with this argument written in the code: «if there are
downloaded maps they are always used, no one wants the answer that on top of being
slower spends data». It is a good argument for the spending and a bad one for driving —
the public server sees this week's cuts, roadworks and reversed directions, and the
phone's tiles are from the date they were downloaded. On a map, "faster" is not worth a
route that no longer exists.

The local **is not** a degraded mode: same engine, same routes, and it is the only
thing there is in a tunnel or with no data. That is why the fallback goes **both ways**
— it is asked of the one that fits and, if it cannot, the other is tried once before
telling the driver there is no route.

On failing, the flags are **not** turned off. Before they were, and that turned a trip
that goes off the maps into a decision for the whole session: the rest of the routes
went the same way even when the other resolved them better. The network's state is told
by NetworkManager, through `QNetworkInformation`, not a `404`.

And `Online`, not "different from Disconnected": in between are `Local` and `Site`,
which are having an IP with no way out to the internet — exactly the phone over USB with
the wifi off.

| | No network | Where it comes from |
|---|---|---|
| **Compute a new route** | **Yes**, with the region downloaded | Valhalla, inside the phone |
| **Guide along an already-computed route** | Yes, always | The whole thing is saved to disk |
| **Return to a route after rebooting** | Yes | 5.7 km take up 3.3 kB |
| **Set a destination by tapping the map**, and the saved ones | Yes | — |
| **Speak** | Yes | Piper, with the model downloaded |
| **Search by name** | **Yes**, with the region downloaded | geocoder-nlp, on the phone |
| **Draw the map** | **Yes**, with the box downloaded | MapLibre + vector tiles |
| **Draw the map outside the box** | Only what has already been visited | QtLocation cache |

Measured with the phone **really isolated** — no default route, no DNS, no ping:

| | |
|---|---|
| Bolnuevo → Murcia | 71 km in 950 ms |
| Murcia → Andorra | 663 km in 1.4 s, crossing two regions |
| Search «cartagena» | 19 ms |
| Full trip with voice | 31 manoeuvres, 53 phrases |
| Murcia → Paris (off the maps) | `400` in 15 ms, and it is requested over the network |

### Seeing the screen without having the phone in front of you

Throughout the whole development I could not **see** the interface: the phone brought no
capture tool, so each badly-placed margin was a round trip with you. `grim` and
`wayshot` are in the repositories but **do not work** —they speak `wlr-screencopy`, from
wlroots, and here the compositor is KWin—.

The one that works is **`spectacle`**, which is packaged:

```sh
apk add spectacle
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
spectacle -b -n -f -o /tmp/pantalla.png
```

KWin **also** offers it over D-Bus (`org.kde.KWin.ScreenShot2`) and it comes cheaper,
but it only authorises executables on its allowlist: a script of one's own gets
`NoAuthorized`. It was tried and discarded.

And the phone has to be **unlocked**: with the lock screen in front, the capture comes
out of the lock screen. That is not just a nuisance for looking — with the session
locked the compositor does not draw the window, and **MapLibre does not request tiles
if it does not draw**. A whole batch of measurements gave "zero tiles" and what was
happening was that the phone was locked.

### The routes: Valhalla inside the phone

Measured on this device, with osmscout-server **stopped**: a 9.23 km route in Murcia is
computed in **0.4 s**, with the instructions in Spanish.

The engine is the same Valhalla as the public server, loaded in here. How you get to it
has its own story, and it is in [`poconav-routes`](poconav-routes): Alpine packages the
library but its `valhalla-dev` **comes empty** —zero headers, checked with `apk info
-L`—, so from C++ there is no door. The only one there is is the Python module, and
that is why the routing lives in a separate process that the application starts on
opening and kills on closing.

That module **did not come in Alpine's package**: the recipe in
[`surya/pmaports/temp/valhalla`](../../../pmaports/temp/valhalla) turns it on. And it
also turns on `ENABLE_DATA_TOOLS`, which seems beside the point but is mandatory:
without it the Python bindings compile and **do not link**
(`valhalla::mjolnir::compute_tileset_build_id: symbol not found`).

**Several regions at once do work.** Valhalla only accepts *one* tile directory, so
keeping the first would leave half of Spain out for having Andorra downloaded and
starting with A. They are joined with symlinks —the tile identifiers are global, so two
regions that do not overlap give different files— and the union is remade only when the
set changes.

### The maps: they are downloaded from the application itself

Settings button, you type the region (`europe/spain`) and it downloads. It is the
routing tiles and the search base. The map's **drawing** is downloaded separately and
by boxes — see below — because it weighs almost double what the routes do.

The one that downloads is [`local-maps`](local-maps), a script **from the package
itself** that the backend runs. It was not rewritten in C++ on purpose: the map server
is not a flat file tree —the versions of each component have to be pulled from its
index, the file list from a catalogue, and Valhalla arrives as numbered packages that
have to be resolved first— and all that was already written and tested.

### The map's drawing: it was downloaded separately and by boxes

**This section used to say it was impossible.** It said a rasteriser would be needed,
that Alpine packages none, and that downloading the OSM tiles ahead violates its policy.
All three things are still true — and the conclusion was false, because it took for
granted that *rasterised* tiles had to be drawn.

With **vector** tiles no rasteriser is needed: the drawing is done by the GPU on the
spot, from data that does fit on disk. That is something **MapLibre** knows how to do,
and the tiles are in the same catalogue we already download the routing ones from.

**Alpine's package does not work as-is**: it is compiled against Qt5 and this
application is Qt6. Qt finds it and rejects it, and the message only comes out with
`QT_DEBUG_PLUGINS=1`:

```
The plugin 'libqtgeoservices_maplibre.so' uses incompatible Qt library. (5.15.0)
```

Without that variable, the only symptom is that `maplibre` does not appear in the
connector list — with the `.so` installed and visible with `ls`. That is why the
self-test now prints the list.

The custom recipe is in
[`../../pmaports/temp/maplibre-native-qt`](../../pmaports/temp/maplibre-native-qt). It
installs in `/usr/lib/poconav` and **not** in `/usr`, and that is not fussiness: the
files are named the same as Qt5's package ones, and that one is used by Pure Maps.
Installing on top would not be coexisting, it would be leaving it without a map.

#### By zoom-7 boxes, not by countries

The catalogue does not split Spain into provinces — only the whole country and,
curiously, Barcelona. But it does split it another way, and for driving it is better:
the packages are named by their **zoom-7 tile**.

| | |
|---|---|
| `7-63-49` — Bolnuevo and Murcia | 112 MB, 21,843 tiles, zoom 7 to 14 |
| All of Spain | 1.9 GB, 23 boxes |

The split knows nothing of administrative borders: it knows where you are. Each region's
row downloads the box **beneath the phone**.

And it is downloaded **separately** from the routes: for Spain it is 1.1 GB of being
able to go against 1.9 GB of being able to see. Joining them would force waiting for both
to navigate, and whoever just wants to arrive should not have to pay for the pretty map.
That is why the backend carries two lists, `maps` and `drawables`, and the row says
which of the two things each region has.

#### The style is read from osmscout-server

107 layers and 83 KB of finely-tuned JSON — which road appears at which zoom, when a
town's name shows — with a `-car` variant meant for driving. Redoing it by hand would be
doing it worse.

It is a **data** dependency, not a service one: nothing is started, its files are read
just as breeze's icons are used. Without that package there is no map without coverage
and the application carries on with the network one.

The style's URLs are rewritten over the already-read JSON and not by changing text
blindly: the file brings the server unresolved —the literal string `HOSTNAMEPORT`— and
search-and-replace would work until the day that string appeared inside a label.

#### Three traps that cost a batch each

**The Y goes the other way.** An `.mbtiles` stores the rows in TMS, counting from the
bottom; the map URLs use XYZ, counting from the top. Without flipping it, real tiles come
out but from the wrong place: the map is drawn mirrored and shifted, which is worse than
not drawing anything because it looks like it works.

**A missing tile is not an error.** The sea, the gaps between regions and abroad are
tiles that do not exist. `204` is answered: with a `404` MapLibre takes it as a failure,
retries, and fills the log for drawing the Mediterranean.

**The `@2x` sprite blocks the whole map.** This screen is dense, so MapLibre asks for the
icons at double resolution. `osmscout-server` only brings the normal one, the server
answered `404` — and **MapLibre does not carry on without its icons**: it asked for the
style, sat there and never got to request a single tile. From outside that looks like
"the connector is in place and does nothing", without a warning. Now, if the `@2x` is not
there, the normal one is served.

#### MapLibre only requests tiles while it DRAWS

And this has to be known before measuring anything, because it invalidates the whole
measurement.

The `osm` connector requests tiles from the camera model, so it requests even if the
window is covered. MapLibre does not: it paints and, on painting, requests. If the window
is not seen —**locked screen**, backlight off (`bl_power=4`), or the window behind
another— it requests **nothing**, and that is indistinguishable from being broken.

Measured: with the session locked, zero tiles. With the window visible, seven within a
few seconds. To check it by hand, with the phone in front and unlocked:

```
POCONAV_LOG=1 poconav-routes &      # the access log, off by default
poconav --only-map                     # a map and nothing else
wget -qO- http://127.0.0.1:8554/status  # brings the 'served' counter
```

### Searching by name: it also works without network

The downloaded region brings `geonlp-primary.sqlite`, the base of `geocoder-nlp`: name,
type, coordinates and hierarchy.

`osmscout-server` queries it by first normalising the text with **libpostal**, which
Alpine does not package — and that was what made me give the search up for blocked for
days. But libpostal is only needed for the hard part, understanding that «c/ mayor 3» is
«calle mayor número 3». To search for a town or a street by its name, matching words is
enough, and that can be done.

Two things were needed:

- **A full-text index.** The table has no index by name, so a `LIKE '%x%'` is a whole
  scan: 2 ms in Andorra (5,604 rows) but unacceptable in Spain. An FTS5 is built **once
  per region**, in a separate file —not inside the base, which the downloader replaces—.
  Measured afterwards: **5–30 ms** per search.
- **Order by what was typed, not by what the base says.** Searching «encamp» the town and
  a bridge called *Pont Tibetà d'Encamp* both have `search_rank` 1000, and the bridge came
  out first. Now what rules is how much the **whole** name resembles, and with that tied,
  what it is: a municipality ahead of a hotel of the same name.

And a fault that cost me a batch: it passed the same `limit` to SQL's `LIMIT`, so it
trimmed **before** ordering — with `limit=4`, the town fell outside the cut and never got
to be compared. Now SQL returns plenty and the order is decided afterwards.

If the downloaded region does not cover what is searched, **it falls back to Nominatim**
instead of saying there is nothing: not finding it at home does not mean it does not
exist.

Accents and case do not matter: «espana» finds «España».

---

## What needs to be in place

The **`gps`** setting. Without it:

- the location engine stays blocked by the pmaports fault and there is only network
  position (measured here: 25 km of error);
- and there is no GeoClue agent, so GeoClue **denies** the position to this application
  without saying anything.

The application detects both things and says so on screen instead of spinning a wheel
forever, but the fix is in `setup/settings/gps`.
