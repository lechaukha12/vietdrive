# Offline demo and driving-scene refresh

## Try it

Driving Mode → **Chạy thử** → **Sài Gòn → Phan Thiết**. No search, route request or GPS recording is required. The previous custom-route option remains available below it. Controls allow speed selection (10–120 km/h), pause/resume, exit and jumps to 0/25/50/75/95 percent. Returning from a finished demo to an earlier point can resume playback.

The ~168 km fixture has 1,263 coordinates. It is a frozen development snapshot, not current navigation advice. Geometry/steps were retrieved once from OSRM during development and bundled in `VietDrive/Resources/Demo/saigon-phanthiet.json`; the app does not call OSRM to play it. Source attribution is included in the fixture and demo sheet: © OpenStreetMap contributors, ODbL, https://www.openstreetmap.org/copyright.

The fixture does **not** supply speed limits or traffic signs. Demo locations pass through a separate instance of the existing offline alert matcher. Starting/seeking/stopping invalidates old asynchronous context results, stops stale voice queues and resets presentation state. Demo does not record a real journey, reroute, or publish simulated GPS to Watch/CarPlay/Live Activity; it pauses outside the foreground.

## Presentation changes

- SQLite caching remains 650 m / 65 m, but reprojection now runs for **every new coordinate or heading**, off the main queue. Pending fixes are coalesced instead of cancelling every in-flight query.
- Event distances advance between fixes, bounded to one second / 24 m. This is presentation-only prediction, never an input to GPS, routing or alerts. The timeline requests 60 fps (30 in Low Power Mode); actual device frame rate still needs road testing.
- The approved design replaces road mesh/polygons with one always-straight road, soft white edges/dashes, simple cross/T junctions, bridge rails and gate outlines. Geometry only selects the kind, side and distance of events; it does not determine the rendered road shape. Toll gates come from existing eligible alerts, not a road's generic toll tag.
- A short firmware link no longer drops a whole longer OSM polyline from scene coverage. Duplicate continuations are not mistaken for a fork. Event density is bounded, and structures/labels render above decorative traffic.
- Pale blue gradient, compact Mazda and Mây, large speed readout, existing limit badge, circular controls, and distance fading for traffic. Existing speed-limit/warning logic is unchanged.
- Actor placement no longer seeds every vehicle from the current road ID. The vehicle budget is halved: up to 8 cars/motorcycles and the unchanged 6 pedestrians where appropriate; spacing and intersection/gate clearance reduce this. Nearby warnings reduce vehicles to at most 3. Two equal lanes are fixed: Mazda and rear-facing traffic in the RIGHT lane, front-facing decorative traffic in the LEFT lane. Mazda no longer sits on the centre divider. Sprite bounds and forward spacing keep vehicles from crossing lanes or looping into Mazda. These are illustrations, **not detected or live traffic**.
- Existing eligible signs stay exclusively on the RIGHT edge. The earlier mistaken left/right sign balancing was removed. Poles remain anchored to the right white line after overlap adjustment, using the shared perspective scale. Signs are not duplicated and their data is not changed. Decorative landmark captions move out of their way. The illustrative-scene footer is no longer displayed.
- Pedestrians appear only on urban road categories, not bridges/tunnels/motorways. Known motorways exclude motorcycles. The left lane is deliberately decorative oncoming traffic, independent of actual one-way metadata; it does not create warnings or signs.

## Verification and limits

The app and XCTest bundle are compiled with the iOS device SDK. Logic tests use production source in a temporary macOS package because no iOS simulator runtime is available. Portrait/landscape images use the production renderer and assets, including seven positions from the bundled route.

The scene is a symbolic road, not a surveyed street reconstruction. Width, lane centering, gate dimensions and actors are illustrative. At ambiguous forks geographic event discovery stops until position/heading resolves it; the visual road stays straight. Missing metadata can mean absent junction/structure events or fewer/no pedestrians, motorcycles or opposing vehicles. No fake periodic junctions or structures are inserted. Compilation and static renders do not prove sustained frame rate or GPS latency on the user's iPhone; those require device testing.

No firmware database, data pipeline, live location service or live alert-matching algorithm was modified for this change.
