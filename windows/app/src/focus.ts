// A dialog's keyboard manners: remember what had focus, put focus inside when it
// opens, keep Tab inside while it is open, and give focus back when it closes.
//
// The page draws overlays with plain DOM events rather than a modal library, so
// this is the one place that owns the focus contract for Settings and the palette.

import { useEffect, useRef, type RefObject } from "react";

const FOCUSABLE = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(",");

/// The items a Tab press can reach, in document order, ignoring anything the page
/// is not actually showing (the Settings pages stay mounted but hidden).
function focusableIn(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
    item => !item.hasAttribute("hidden") && item.getClientRects().length > 0,
  );
}

export function useDialogFocus(
  open: boolean,
  root: RefObject<HTMLElement | null>,
  initial?: string,
  restore?: string,
) {
  // The opener is recorded as it is focused, not when the dialog opens: by then the
  // button that opened it may already have been replaced (Settings does exactly that).
  const lastFocused = useRef<HTMLElement | null>(null);
  useEffect(() => {
    const onFocusIn = (event: FocusEvent) => {
      if (event.target instanceof HTMLElement) lastFocused.current = event.target;
    };
    document.addEventListener("focusin", onFocusIn);
    return () => document.removeEventListener("focusin", onFocusIn);
  }, []);

  useEffect(() => {
    if (!open) return;
    const element = root.current;
    if (!element) return;
    const previous = lastFocused.current;

    // The first focus is deferred one frame: the overlay has just been unhidden,
    // and an element without a box cannot take focus yet.
    const frame = requestAnimationFrame(() => {
      const preferred = initial ? element.querySelector<HTMLElement>(initial) : null;
      const target = preferred ?? focusableIn(element)[0] ?? element;
      target.focus({ preventScroll: true });
    });

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Tab") return;
      const items = focusableIn(element);
      if (items.length === 0) {
        event.preventDefault();
        element.focus({ preventScroll: true });
        return;
      }
      const first = items[0];
      const last = items[items.length - 1];
      const active = document.activeElement;
      if (event.shiftKey && (active === first || !element.contains(active))) {
        event.preventDefault();
        last.focus({ preventScroll: true });
      } else if (!event.shiftKey && (active === last || !element.contains(active))) {
        event.preventDefault();
        first.focus({ preventScroll: true });
      }
    };

    element.addEventListener("keydown", onKeyDown);
    return () => {
      cancelAnimationFrame(frame);
      element.removeEventListener("keydown", onKeyDown);
      // The opener may have gone away (Settings replaces its own button with a back
      // button): fall back to the selector the dialog names, then let the browser keep
      // focus where it is.
      if (previous?.isConnected && previous.getClientRects().length > 0) {
        previous.focus({ preventScroll: true });
      } else if (restore) {
        document.querySelector<HTMLElement>(restore)?.focus({ preventScroll: true });
      }
    };
  }, [open, root, initial, restore]);
}
