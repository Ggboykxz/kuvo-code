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
