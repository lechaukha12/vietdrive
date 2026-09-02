# Driving mode visual design

The driving screen uses one full-width animated road with informational overlays. The vehicle is a generated illustration, not the downloaded reference photograph. Existing DriveSnapshot and visibleAlerts remain the source for all live driving information.

## Vehicle asset

- Asset: `VietDriveIOS/VietDrive/Resources/Assets.xcassets/DrivingMazdaCX5Rear.imageset/mazda-cx5-rear.png`
- Source: built-in image generation, followed by a transparent-background edit; alpha verified.
- Reference: [white 2024 Mazda CX-5 rear, Brighton Toyota](https://www.brightontoyota.com.au/cars/used-white-2024-mazda-cx-5-155762)
- [Mazda official model information](https://news.mazdausa.com/vehicles-2024-cx-5)
- License plate: `86A 26427`.

## Generation prompt

Use case: stylized-concept. Asset type: transparent PNG vehicle sprite for the VietDrive iOS driving dashboard. Input image 1 is a geometry/reference photo ONLY of a white Mazda CX-5 rear. Generate a completely new high-quality polished realistic 3D product illustration, not a photo cutout. Depict the white Mazda CX-5 KF SUV accurately in a perfectly centered straight rear view, camera slightly above tail lamp height so only a little roof is visible, no side three-quarter angle. Faithful wide rear window, roof spoiler, Mazda wing emblem centered, sculpted liftgate, CX-5 badge on left, slim red tail lights with their characteristic illuminated outline, black lower bumper, dual round chrome exhausts, grounded wide tires. Pearl white paint with subtle cool blue ambient reflections and dimensional soft studio lighting, crisp realistic materials, refined proportions, no cartoon outlines. Vietnamese white license plate at original liftgate position with exact bold black text '86A 26427'. Tail lamps softly lit, high center brake light NOT brightly braking. Whole car visible including both mirrors and rear tires, fills about 85% of canvas width, centered, image canvas 1024x1024, minimal 6% transparent margins, car silhouette must not be cut off. Truly transparent background with alpha, no colored background, no checkerboard painted in, no ground or road, no scenery, no people, no text outside the plate and car badges, no dealer sticker, no watermark. Subtle contact shadow directly beneath rear tires is okay and must blend using alpha. This is a production illustration to overlay on a pale blue animated road, not a UI mockup.

## Final background edit prompt

Use case: background-extraction. Edit target: the attached generated white Mazda CX-5 rear illustration. Remove the entire gray-and-white CHECKERBOARD pattern from around the car and replace it with genuinely TRANSPARENT pixels (PNG alpha channel, zero alpha outside the subject). The checkerboard in this input is baked into the RGB image and must be deleted, not redrawn. Output must be RGBA with a transparent background, NOT an RGB file with white, gray, checkerboard, or black background. Preserve the car exactly: the white pearl body, rear window, Mazda logo, tail lights, dual exhaust, tires, and the license plate 86A 26427. Keep the exact centered straight rear viewpoint and framing. Retain only a subtle translucent contact shadow under the tires. No new objects, no background, no checkerboard. Production clean transparent-cutout sprite.

## Compact cockpit refinement

- The vehicle is capped at 194 points in portrait and 180 in landscape, with adaptive sizing on shorter screens and space reserved for roadside signs.
- May uses the existing mascot assets beside the vehicle rather than in a popup, responding to GPS availability, speed and the nearest existing alert. The `showMascotOnMap` preference now covers both screens.
- The stopped/slogan capsule is removed. Only GPS and overspeed status remain as lightweight captions; controls use a compact search pill and two accessible circular buttons.
- Road markings move at a rate derived from GPS speed, only above 2 km/h with a fix and an active scene. System Reduce Motion disables road animation; the mascot-specific setting only disables mascot animation.
- Automatic screen sleep is suppressed while Driving Mode is enabled, the signed-in screen is active and the app is in the foreground. Disabling the mode, signing out or leaving the foreground restores the system idle timer. Manual locking remains possible.
- Visual checks use the actual presentational SwiftUI code rendered at portrait, short-screen and landscape sizes. These previews use sample data, not simulated data in the deployed app.
- Verified native render checks: road moves, freezes at zero speed, pauses and resumes; mascot moves, freezes when disabled, resumes and freezes with its reduced-motion preference. Rebuilding the mascot's animated subtree prevents old repeating animations from continuing after a pause.
- iPhone-target Debug build succeeds. Automatic-lock timing still needs a hands-off physical-device check beyond the configured Auto-Lock interval; render checks cannot verify that iOS behavior.

## Refined vehicle prompt (built-in image generation)

Use case: stylized-concept.
Asset type: a single transparent PNG car sprite for VietDrive iOS driving dashboard, displayed at approximately 200 points wide.
Input image 1: reference photo for Mazda CX-5 rear geometry only. Input image 2: existing sprite to improve; its flat, heavy, broad appearance should NOT be copied.
Primary request: create a newly drawn, refined premium 3D illustration of this white Mazda CX-5, straight centered rear view with slightly elevated camera showing some roof for better depth. Softly sculpted, clean surfaces, natural believable SUV proportions, subtle light-blue ambient reflections on pearl-white paint, soft diffused lighting. A polished small-scale navigation app vehicle illustration rather than a photorealistic cutout. Elegant rather than toy-like; no black outlines, no exaggerated wide tires or cartoon deformation. Keep the correct rear window, Mazda wing emblem, slender CX-5 rear lamps, black lower bumper and dual round exhausts. Taillights red but high central brake lamp unlit. Rear window dark blue-gray, avoid detailed interior seats.
Text: Vietnamese plate exactly '86A' on first line and '26427' on second line, black on white, centered at correct liftgate location.
Composition: whole car visible including tires and mirrors, equal margins, 85% canvas width, front-to-back axis exactly vertical, no sideways rotation. Slight elevated rear view, NOT top-down.
Backdrop: genuinely transparent RGBA alpha channel outside car, with only a very soft semitransparent contact shadow beneath tires. No checkerboard, no white rectangular background, no road, no scenery, no other cars, no mascot, no text outside plate and tiny vehicle badges. This will be composited over an animated pale-blue road.

## Refined vehicle transparency edit notes

The built-in background-extraction edit removed the white/checkerboard backdrop, retained the elevated rear view and exact plate, and produced the final RGBA asset. Its alpha channel was checked before integration.

## Distance-driven roadside signs

- The current-speed, current-limit and next-limit readout remains unchanged. The standalone upcoming-alert list and horizontal sign strip are removed.
- Up to three existing incoming alerts appear as posts on the right shoulder of the same perspective road as the car. Very short scenes may show fewer posts to keep them legible.
- Face size and depth follow the supplied distance, with a 0.65-second visual interpolation while moving. There is no timer-driven extrapolation of alert distances. System Reduce Motion and inactive scenes disable interpolation.
- Faces and metre labels are separated when they overlap; displayed metre values are never altered. Right-side placement and pole geometry are illustrative, not a claim about surveyed roadside or lane positions.
- View-local passage memory uses reliable moving GPS fixes near an incoming sign to suppress its visual after passing. It tolerates small GPS drift, can rearm an incoming sign after a U-turn, and is pruned when the engine removes the sign. Missing GPS hides the sign layer. This does not alter databases, map matching, speed-limit determination, notifications or voice warnings.
- Ten regression tests cover selection, passage, reapproach, GPS quality, projection and collision bounds. They pass against the actual presentation helpers in a native macOS XCTest runner. The iOS app and test target also build successfully; these checks are not an on-road iPhone test.
- Native SwiftUI previews were checked in portrait, short portrait and landscape, including approaching and passing the first sign. Preview positions are sample data only.
