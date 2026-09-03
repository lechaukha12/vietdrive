# Driving Mode — symbolic straight-road scene

## September 2026 additions

The fixed demo and scene refresh are described in [driving-demo-offline.md](driving-demo-offline.md).

### DrivingPedestrianRear

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingPedestrianRear.imageset/vehicle.png`

```text
Use case: stylized-concept. Production game sprite for a light iOS driving scene: one adult pedestrian, full body seen directly from behind, casually walking away, one leg in front of the other, relaxed arm swing. Pale coral short-sleeve shirt, charcoal trousers, white sneakers, natural black hair. Polished realistic 3D render with soft daylight, clean recognisable silhouette. Isolated cutout on a genuinely transparent PNG alpha background. Centered square composition, full head and feet with 8% padding, occupies 84% frame height. No ground, no shadows, no text, no extra people.
```

### DrivingPedestrianFront

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingPedestrianFront.imageset/vehicle.png`

```text
Use case: stylized-concept. Production game sprite for a light iOS driving scene: one adult pedestrian, full body seen directly from the front, casually walking toward camera, one leg in front of the other, relaxed arm swing. Muted teal short-sleeve shirt, beige trousers, white sneakers, natural black hair. Polished realistic 3D render with soft daylight, clean recognisable silhouette. Isolated cutout on a genuinely transparent PNG alpha background. Centered square composition, full head and feet with 8% padding, occupies 84% frame height. No ground, no shadows, no text, no extra people.
```

## Scope

The scene is presentation-only. It does not create a MapLibre map, a location manager, a route, a new warning, or a speed limit. Existing firmware matching, alert eligibility, warning audio and the data pipeline remain unchanged.

- `DrivingSceneStore` opens independent SQLite connections with `SQLITE_OPEN_READONLY` on a utility queue. A 650 m window refreshes after 65 m of movement. Reads stop being requested when this screen is inactive.
- Firmware link geometry is preferred for the visual anchor. Existing OSM road metadata supplies lanes, one-way, bridge, tunnel and layer only after geometric agreement. Unknown tags do not imply a bridge/tunnel.
- The approved renderer always draws one straight corridor, with soft white edges on a pale blue background. It does not draw the actual road mesh, parallel roads, curves or road polygons. No new online map or traffic service is used.
- Geometry supplies distances and branch sides for schematic T/cross junctions and interchanges. A bridge/tunnel entry must connect and align with the forward path; a bridge crossing overhead is not an entry. Toll gates use already-eligible toll alerts. At most two events within 650 m are shown; toll/structure events take precedence over nearby generic junctions. Nothing periodically invents events when geometry is absent.
- The forward path continues through unambiguous connected geometry only. It does not predict the user's turn at a fork. Missing/poor GPS or missing geometry leaves the illustrative straight road, without fabricated geographic events. The on-screen “Đường & giao thông minh hoạ” footer was removed at the user's request; the scene remains illustrative.
- Traffic sprites are **simulated**, not detected traffic. Vehicle seeds were reduced by 50%: up to 8 vehicles plus the unchanged 6 pedestrians, reduced to 3 vehicles near a warning, subject to spacing and intersection/gate clearance. Motorways exclude motorcycles/pedestrians. Per the user's clarified design, the left lane always contains decorative oncoming traffic; this no longer depends on one-way metadata and is not a claim about actual road direction.
- The ribbon has exactly two equal-width lanes. Mazda is centred in the RIGHT lane, not on the divider. Same-direction cars and motorcycles stay in the right lane ahead of Mazda; the left lane shows front-facing oncoming sprites only. Full sprite bounds stay on their own side of the divider and within the road edges; pedestrians remain outside. Stable IDs persist through loops without side changes. Far actors fade; drawing size is capped by scene height.
- Distance integration drives road dashes and traffic. Inactive screens, stopped vehicles and Reduce Motion pause animation. The speed/limit readout and controls are simplified, with Mây retained. Speed/limit values and overspeed eligibility are unchanged.
- All eligible traffic signs stay on the RIGHT edge. The mistaken sign-balancing function and side-assignment state were removed entirely: only the two VEHICLE lanes are balanced. Face/label separation stays on the right, and pole X is recomputed from the final base Y so it stays on the white line. Landmark captions avoid sign faces/labels. Alert IDs, distances, assets, passage filtering and warning eligibility are unchanged. Left-side traffic does not create any alerts or signs.
- Bridge rails, tunnel arches and toll gantries are implemented; an interchange still shares the branch-line drawing with a junction (no separate multilevel interchange illustration). Appearance depends on the existing geometry/alert conditions, not a timed sequence of sample landmarks.
- Mazda uses its straight rear sprite in this design; existing angle assets remain available. Its plate is rendered as real text: 86A / 26427. Brake-light feedback is illustrative speed-decrease feedback, not a signal read from the vehicle.

## Verification

52 XCTest cases across scene, roadside presentation, playback and fixture loading cover geometry, branch sides, stable event IDs, distance progression, grade separation, forks, link continuation, halved traffic density, equal lane widths, right-lane Mazda anchoring, sprite bounds/non-overlap, right-only signs after reordering/passage, caption clearance, background time, read-only database access, seeking and offline route validation. They run on production source files through a temporary macOS Swift package when iOS simulator runtimes are unavailable. This is not an on-device UI test.

SwiftUI previews use the production scene renderer and a copy of the cockpit layout with macOS image-loading adapters, actual assets, portrait/landscape frames, and actual database queries along the fixed demo. Compilation and previews do not establish sustained frame rate or field GPS latency on iPhone.

## Asset generation

Mode: built-in `imagegen`, not the fallback CLI. Nine new RGBA PNG assets; previous vehicle and Mây assets remain intact. Rejected checkerboard-background variants were not bundled. All selected PNGs have an alpha channel. Mây reuses existing poses.

The prompt set below records the final generation or final edit prompt. Motorcycle rear used a background-extraction pass on the first generated sprite; its original generation prompt is retained below as well.

### DrivingMazdaRearV2

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingMazdaRearV2.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-7fab57b7-7027-4bc1-b9a6-99f630bee5e3.png`

```text
Use case: stylized-concept
Asset type: transparent PNG vehicle sprite for VietDrive iOS 2.5D driving scene.
Input image 1 is an identity reference for the user's white Mazda CX-5, not a background.
Create one polished restrained stylized-realistic white Mazda CX-5 SUV, exact straight rear view, slightly elevated camera (see a little roof), full vehicle and all wheels visible, centered occupying 84% width and 78% height of a square canvas. Keep recognizable CX-5 proportions, slim red rear lamps, black lower bumper, dark rear glass, side mirrors. A blank clean rectangular white license plate with NO letters/numbers, centered at about x50%, y64% of canvas; plate text will be rendered by the app. Soft neutral daylight from upper left. Crisp silhouette, subtle simplified materials, premium friendly iOS illustration, no motion blur. Truly transparent alpha background, no floor, no scenery, no baked cast shadow, no border, no watermark. Only ONE vehicle.
```

### DrivingMazdaLeft

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingMazdaLeft.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-8f6cc5e6-8d7f-46e1-bcb9-487076d61946.png`

```text
Use case: stylized-concept. Asset type: one transparent PNG traffic vehicle sprite for VietDrive iOS 2.5D driving scene. Reference image 1 provides lighting and restrained stylized-realistic rendering style, NOT the vehicle type unless Mazda is specified. Full vehicle visible, centered with 8% transparent padding, square canvas, slightly elevated rear-follow camera (see a little roof), neutral daylight from upper left, crisp clean edges. Genuinely transparent alpha background. No floor, no scene, no baked cast shadow, no border, no motion blur, no watermark, no text or plate digits. ONE vehicle only.
Subject: Same exact white Mazda CX-5 as reference, rear view turned a subtle 12 degrees toward the LEFT of screen, so a small amount of its left side becomes visible. Same proportions and scale. White blank rear license plate. Not side profile. Preserve CX-5 lamps and trim.
```

### DrivingMazdaRight

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingMazdaRight.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-f25ee120-ac4e-4168-a545-dfc264e735f3.png`

```text
Use case: stylized-concept. Asset type: one transparent PNG traffic vehicle sprite for VietDrive iOS 2.5D driving scene. Reference image 1 provides lighting and restrained stylized-realistic rendering style, NOT the vehicle type unless Mazda is specified. Full vehicle visible, centered with 8% transparent padding, square canvas, slightly elevated rear-follow camera (see a little roof), neutral daylight from upper left, crisp clean edges. Genuinely transparent alpha background. No floor, no scene, no baked cast shadow, no border, no motion blur, no watermark, no text or plate digits. ONE vehicle only.
Subject: Same exact white Mazda CX-5 as reference, rear view turned a subtle 12 degrees toward the RIGHT of screen, so a small amount of its right side becomes visible. Same proportions and scale. White blank rear license plate. Not side profile. Preserve CX-5 lamps and trim.
```

### DrivingSedanRear

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingSedanRear.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-764db95f-8233-4775-a317-c663eb3cf1c4.png`

```text
Use case: stylized-concept. Generate a single production sprite: straight REAR view of a compact BLUE SEDAN with a clearly visible separate low TRUNK BOOT and a THREE-BOX sedan silhouette, NOT a hatchback, NOT an SUV. Slightly elevated camera, approximately 8 degrees looking down. Stylized realistic polished 3D render for an iOS driving scene. Soft daylight, understated blue body, dark glass, red tail lamps, blank small dark license plate, no logos or letters. Square canvas, centered full car with wheels intact, vehicle occupies about 76% canvas width and 65% height. GENUINELY TRANSPARENT BACKGROUND with alpha channel: do not paint checkerboard or white. No ground plane, no shadow, no scenery. One car only.
```

### DrivingSedanFront

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingSedanFront.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-c6012035-dc85-464c-82f6-9fc6c98ae15e.png`

```text
Use case: stylized-concept. Asset type: one transparent PNG traffic vehicle sprite for VietDrive iOS 2.5D driving scene. Reference image 1 provides lighting and restrained stylized-realistic rendering style, NOT the vehicle type unless Mazda is specified. Full vehicle visible, centered with 8% transparent padding, square canvas, slightly elevated rear-follow camera (see a little roof), neutral daylight from upper left, crisp clean edges. Genuinely transparent alpha background. No floor, no scene, no baked cast shadow, no border, no motion blur, no watermark, no text or plate digits. ONE vehicle only.
Subject: A compact muted steel-blue four-door sedan, straight FRONT view coming toward camera. Simple unbranded modern car with clear white headlamps, dark windshield and modest proportions. Whole body and tires visible.
```

### DrivingSUVRear

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingSUVRear.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-f71af68d-f104-4ce7-a0b3-fbdef465658b.png`

```text
Use case: stylized-concept. Asset type: one transparent PNG traffic vehicle sprite for VietDrive iOS 2.5D driving scene. Reference image 1 provides lighting and restrained stylized-realistic rendering style, NOT the vehicle type unless Mazda is specified. Full vehicle visible, centered with 8% transparent padding, square canvas, slightly elevated rear-follow camera (see a little roof), neutral daylight from upper left, crisp clean edges. Genuinely transparent alpha background. No floor, no scene, no baked cast shadow, no border, no motion blur, no watermark, no text or plate digits. ONE vehicle only.
Subject: A warm silver-gray midsize SUV, straight REAR view driving away. Simple unbranded modern SUV with roof rails, red rear lamps and black lower trim. Whole body and tires visible.
```

### DrivingMotorbikeRear

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingMotorbikeRear.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-99c27c4e-ef85-49c7-b0fc-2bc42232c494.png`

```text
Use case: background-extraction. Edit target: the supplied image. Remove ONLY the entire checkerboard background to genuinely transparent alpha=0 pixels. Output a true RGBA PNG cutout, NOT a painted checkerboard, NOT a white or solid background. Preserve the vehicle, rider if present, colors, silhouette, framing and every foreground detail exactly unchanged. Remove background between mirrors, wheels and legs too. No extra shadow or text.
```

### DrivingSUVFront

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingSUVFront.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-a1e85f34-0b7d-4f68-9676-ca80bbdddc66.png`

```text
A single silver compact SUV viewed directly from the front, slightly elevated camera, clean polished realistic 3D game sprite. Full vehicle centered in a square canvas, subtle daylight highlights, dark windshield, understated grille without any badge, blank plate. Isolated cutout with a genuinely transparent background (PNG alpha channel). No ground plane, no shadows, no scenery. Occupy 85% of the frame.
```

### DrivingMotorbikeFront

Final project asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingMotorbikeFront.imageset/vehicle.png`

Generated source: `/Users/lechaukha12/.codex/generated_images/01a041f1-1915-7303-950b-a312f94bed19/exec-790929ae-af49-4fe5-82c0-25916b9b16b9.png`

```text
A single turquoise commuter scooter with an adult rider wearing a white helmet, navy jacket and jeans, seen directly from the front. Clean polished realistic 3D game sprite. Full helmet, mirrors and wheels inside the square frame, slight elevated viewpoint. Isolated cutout with genuinely transparent background (PNG alpha channel). No ground plane, no shadows, no scenery, no text. Occupy 90% of frame height.
```

### Original motorcycle rear generation

```text
Use case: stylized-concept. Asset type: one transparent PNG traffic vehicle sprite for VietDrive iOS 2.5D driving scene. Reference image 1 provides lighting and restrained stylized-realistic rendering style, NOT the vehicle type unless Mazda is specified. Full vehicle visible, centered with 8% transparent padding, square canvas, slightly elevated rear-follow camera (see a little roof), neutral daylight from upper left, crisp clean edges. Genuinely transparent alpha background. No floor, no scene, no baked cast shadow, no border, no motion blur, no watermark, no text or plate digits. ONE vehicle only.
Subject: A teal Vietnamese commuter motor scooter with one adult rider, straight REAR view moving away. Rider wears navy jacket, blue jeans, proper light helmet, both hands on handlebars, feet on footboard. Full rider helmet and both wheels visible, realistic narrow silhouette, no caricature.
```
