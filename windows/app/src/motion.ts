// The Mac's own motion, as numbers the app can use.
//
// The Mac app's animation is one spring — .spring(response: 0.32, dampingFraction: 0.86)
// (KuvoCode/Design/Theme.swift:21-31) — and it is used for everything that moves on its
// own: the tab pill sliding to the tab you pick, the panels arriving, the rows settling.
// A SwiftUI spring is a mass on a spring: ω = 2π / response, and the damping is 2ζω.
// Those are the numbers Motion's spring takes.
//
//   ω  = 2π / 0.32 = 19.635
//   k  = ω²        = 385.5
//   c  = 2ζω       = 33.8

import type { Transition } from "motion/react";

export const macSpring: Transition = {
  type: "spring",
  stiffness: 385.5,
  damping: 33.8,
  mass: 1,
};

/// The spring, and nothing when the app (or the system) asks for less movement.
export const macSpringOrStill = (reduced: boolean): Transition =>
  reduced ? { duration: 0 } : macSpring;

/// The image viewer's own timings (ImageViewer.swift:22, 28, 40): the picture fades in over
/// 160 ms and goes out over 140, and the window under it dims over 150 — the system's own
/// ease-out, every one of them.
export const viewerFade = { duration: 0.16, ease: "easeOut" as const };
export const viewerClose = { duration: 0.14, ease: "easeOut" as const };
export const viewerDim = { duration: 0.15, ease: "easeOut" as const };
