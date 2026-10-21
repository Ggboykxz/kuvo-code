// The Mac's marks, drawn.
//
// The Mac app draws its symbols as SF Symbols: filled shapes, at the system's own sizes.
// Here they are drawn instead — the same silhouettes, on the same 16 pt optical grid, with
// a 1.5 pt stroke at 16 pt, round caps and joins, in `currentColor` (the house rule,
// `docs/MAC-UI-MAP.md` §7). No emoji, no text glyph standing in for a mark, no icon font.
//
// The two the Mac draws rather than borrowing are here too: the folder (a 16 × 13 grid, a
// faint fill of the same ink over its outline, `FolderIcon.swift`) and the app's own prompt
// mark, the `>_` the spinner draws (`Spinner.swift:153-177`).

import type { CSSProperties } from "react";

export type SymbolName =
  | "xmark"
  | "plus"
  | "chevron.right"
  | "chevron.down"
  
  | "chevron.up"
  | "arrow.down"
  | "arrow.up"
  | "arrow.clockwise"
  | "tray.and.arrow.down"
  | "list.bullet"
  | "doc"
  | "doc.text"
  | "doc.badge.plus"
  | "doc.on.doc"
  | "pencil"
  | "terminal"
  | "globe"
  | "questionmark.bubble"
  | "wand.and.stars"
  | "wrench.and.screwdriver"
  | "chevron.left.forwardslash.chevron.right"
  | "checkmark"
  | "magnifyingglass"
  | "arrow.triangle.branch"
  | "arrow.uturn.backward"
  | "square.and.pencil"
  | "gearshape"
  | "paintpalette"
  | "command"
  | "person.2"
  | "graduationcap"
  | "slash.circle"
  | "folder"
  | "person.crop.circle"
  | "gauge.with.dots.needle.50percent"
  | "archivebox"
  | "checkmark.shield"
  | "cpu"
  | "puzzlepiece.extension"
  | "server.rack"
  | "bubble.left.and.text.bubble.right";

/// The paths, on the 16 pt grid, in the Mac's own order.
const PATHS: Record<SymbolName, string[]> = {
  "xmark": ["M4 4l8 8", "M12 4l-8 8"],
  "plus": ["M8 3.4v9.2", "M3.4 8h9.2"],
  "chevron.right": ["M6.5 3.5L10.5 8l-4 4.5"],
  "chevron.down": ["M3.5 6.5L8 10.5l4.5-4"],
  "chevron.up": ["M3.5 9.5L8 5.5l4.5 4"],
  "arrow.down": ["M8 3v9.5", "M4.5 9L8 12.5 11.5 9"],
  "arrow.up": ["M8 13V3.5", "M4.5 7L8 3.5 11.5 7"],
  "arrow.clockwise": ["M4 9.5A4.5 4.5 0 1 1 12 8", "M12 8l-2-1.6", "M12 8l2-1.6"],
  "tray.and.arrow.down": ["M2.5 9.5v3h11v-3", "M8 2.5v5", "M5.5 5L8 7.5 10.5 5"],
  "list.bullet": ["M6 4.2h7.5", "M6 8h7.5", "M6 11.8h7.5", "M3 4.2h.01", "M3 8h.01", "M3 11.8h.01"],
  "doc.on.doc": ["M5.5 5.5h-3A1.5 1.5 0 0 0 1.5 1.5H7.5", "M3 5.5H2.2A1.3 1.3 0 0 0 1.3 1.3H5.5", "M9 2.2h3.3A1.5 1.5 0 0 1 1.5 1.5v6.8a1.5 1.5 0 0 1-1.5 1.5H8.2a1.5 1.5 0 0 1-1.5-1.5V6.2a1.5 1.5 0 0 1 1.5-1.5", "M6 8.2h5"],
  "checkmark": ["M3.2 8.4l3.1 3.1 6.5-6.5"],
  "doc": ["M4 2.6h5l3 3v7.8H4z", "M9 2.6v3h3"],
  "doc.text": ["M4 2.6h5l3 3v7.8H4z", "M9 2.6v3h3", "M5.8 8h4.4M5.8 10.4h3"],
  "doc.badge.plus": ["M4 2.6h4.2l2.8 2.8v7.6H4z", "M8.2 2.6v2.8h2.8", "M11.6 9.4v3.4M9.9 11.1h3.4"],
  "pencil": ["M3 13l.9-3 6.8-6.8a1.2 1.2 0 0 1 1.7 0l.4.4a1.2 1.2 0 0 1 0 1.7L6 12.1 3 13Z", "M9.8 4l2.2 2.2"],
  "terminal": ["M2.6 3.4h10.8v9.2H2.6z", "M5 6.4l2 1.8-2 1.8M8.6 10.4h2.6"],
  "globe": ["M8 2.4a5.6 5.6 0 1 0 0 11.2 5.6 5.6 0 0 0 0-11.2Z", "M2.6 8h10.8", "M8 2.4c1.6 1.6 2.4 3.4 2.4 5.6s-.8 4-2.4 5.6c-1.6-1.6-2.4-3.4-2.4-5.6s.8-4 2.4-5.6Z"],
  "questionmark.bubble": ["M8 2.4a5.6 5.6 0 0 0-3.3 10.1c.6.5 1 1.1 1 1.9v.4h4.6v-.4c0-.8.4-1.4 1-1.9A5.6 5.6 0 0 0 8 2.4Z", "M6.6 7.2a1.5 1.5 0 1 1 2.2.8c-.5.4-.8.8-.8 1.4"],
  "wand.and.stars": ["M3 13l6.4-6.4", "M9.4 4.2l.7 1.6 1.6.7-1.6.7-.7 1.6-.7-1.6-1.6-.7 1.6-.7Z", "M12.6 8.6l.5 1.1 1.1.5-1.1.5-.5 1.1-.5-1.1-1.1-.5 1.1-.5Z"],
  "wrench.and.screwdriver": ["M10.6 2.6a3.2 3.2 0 0 0-3.9 4.2L2.8 10.7a1.2 1.2 0 0 0 1.7 1.7l3.9-3.9a3.2 3.2 0 0 0 4.2-3.9l-1.9 1.9-1.6-.4-.4-1.6Z", "M6.4 4.4l5.2 5.2"],
  "chevron.left.forwardslash.chevron.right": ["M5.8 4.4L2.8 8l3 3.6", "M6.8 12.4l1.4-8.8", "M10.2 4.4l3 3.6-3 3.6"],
  "magnifyingglass": ["M7 2.6a4.4 4.4 0 1 0 0 8.8 4.4 4.4 0 0 0 0-8.8Z", "M10.4 10.4L13.4 13.4"],
  "arrow.triangle.branch": ["M5.2 2.6v7.2a2.6 2.6 0 0 0 2.6 2.6h4.4", "M5.2 2.6L2.6 5.2M5.2 2.6l2.6 2.6", "M11 9.6h1.2a1.4 1.4 0 0 0 1.4-1.4V4.4", "M11 9.6L9.4 8M11 9.6l1.6-1.6"],
  "arrow.uturn.backward": ["M4 6.6h5.4a3.4 3.4 0 0 1 0 6.8H6.6", "M6.6 3.6L3.4 6.6l3.2 3"],
  "gearshape": ["M5.7 8.0a2.3 2.3 0 1 0 4.6 0a2.3 2.3 0 1 0 -4.6 0z", "M8 1.9v1.6M8 12.5v1.6M1.9 8h1.6M12.5 8h1.6M3.7 3.7l1.1 1.1M11.2 11.2l1.1 1.1M12.3 3.7l-1.1 1.1M4.8 11.2l-1.1 1.1"],
  "paintpalette": ["M8 2.2a5.8 5.8 0 1 0 0 11.6c.9 0 1.3-.5 1.3-1.1 0-.6-.5-.9-.5-1.5 0-.6.5-1.1 1.2-1.1h1.1c1.4 0 2.5-1.1 2.5-2.7A5.8 5.8 0 0 0 8 2.2z", "M4.6 6.0a0.8 0.8 0 1 0 1.6 0a0.8 0.8 0 1 0 -1.6 0z", "M7.2 4.7a0.8 0.8 0 1 0 1.6 0a0.8 0.8 0 1 0 -1.6 0z", "M9.7 6.0a0.8 0.8 0 1 0 1.6 0a0.8 0.8 0 1 0 -1.6 0z"],
  "command": ["M5 6V5a2 2 0 1 1 2 2h2a2 2 0 1 1 2-2V5"],
  "person.2": ["M3.8 5.5a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0 -4.4 0z", "M2.4 12.7c.4-2 1.8-3.2 3.6-3.2s3.2 1.2 3.6 3.2", "M10.4 3.8a2 2 0 0 1 0 3.8M11.3 9.8c1.3.3 2.1 1.3 2.4 2.9"],
  "graduationcap": ["M3 3.2h4.2A1.8 1.8 0 0 1 9 5v8H4.8A1.8 1.8 0 0 1 3 11.2z", "M13 3.2H8.8A1.8 1.8 0 0 0 7 5v8h4.2A1.8 1.8 0 0 0 13 11.2z"],
  "slash.circle": ["M2.4 8.0a5.6 5.6 0 1 0 11.2 0a5.6 5.6 0 1 0 -11.2 0z", "M6 10.4L10 5.6"],
  "folder": ["M2 4.5A1.5 1.5 0 0 1 3.5 3h2.2l1.4 1.5h5.4A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z"],
  "person.crop.circle": ["M2.4 8.0a5.6 5.6 0 1 0 11.2 0a5.6 5.6 0 1 0 -11.2 0z", "M6.1 6.6a1.9 1.9 0 1 0 3.8 0a1.9 1.9 0 1 0 -3.8 0z", "M4.6 12.4c.4-1.8 1.7-2.8 3.4-2.8s3 .9 3.4 2.8"],
  "gauge.with.dots.needle.50percent": ["M2.4 11.5a5.6 5.6 0 1 1 11.2 0", "M8 11.5l2.8-3.4", "M7.0 11.5a1.0 1.0 0 1 0 2.0 0a1.0 1.0 0 1 0 -2.0 0z"],
  "archivebox": ["M3.2 3.0h9.6a1.0 1.0 0 0 1 1.0 1.0v1.0a1.0 1.0 0 0 1 -1.0 1.0h-9.6a1.0 1.0 0 0 1 -1.0 -1.0v-1.0a1.0 1.0 0 0 1 1.0 -1.0z", "M3.4 6v5.7A1.3 1.3 0 0 0 4.7 13h6.6a1.3 1.3 0 0 0 1.3-1.3V6M6.2 8.5h3.6"],
  "checkmark.shield": ["M8 1.9l5 1.8v3.7c0 3-1.8 5.2-5 6.7-3.2-1.5-5-3.7-5-6.7V3.7z", "M5.7 8l1.6 1.6 3.1-3.2"],
  "cpu": ["M4.2 3.4h7.6a2.0 2.0 0 0 1 2.0 2.0v5.2a2.0 2.0 0 0 1 -2.0 2.0h-7.6a2.0 2.0 0 0 1 -2.0 -2.0v-5.2a2.0 2.0 0 0 1 2.0 -2.0z", "M2.2 6.4h11.6M2.2 9.6h11.6M5 3.4v9.2"],
  "puzzlepiece.extension": ["M3 6.5h3.2V5a1.8 1.8 0 1 1 3.6 0v1.5H13v3.2h-1.5a1.8 1.8 0 1 0 0 3.6H13v.2H3V11.5h1.5a1.8 1.8 0 1 0 0-3.6H3z"],
  "server.rack": ["M3.6 2.6h8.8a1.2 1.2 0 0 1 1.2 1.2v1.8a1.2 1.2 0 0 1 -1.2 1.2h-8.8a1.2 1.2 0 0 1 -1.2 -1.2v-1.8a1.2 1.2 0 0 1 1.2 -1.2z", "M3.6 9.2h8.8a1.2 1.2 0 0 1 1.2 1.2v1.8a1.2 1.2 0 0 1 -1.2 1.2h-8.8a1.2 1.2 0 0 1 -1.2 -1.2v-1.8a1.2 1.2 0 0 1 1.2 -1.2z", "M4.8 4.7h.01M4.8 11.3h.01"],
  "square.and.pencil": ["M9.2 3.2h3.6v3.6", "M9.4 6.4L4.2 11.6l-2 .6.6-2 .4.6.6-2-1.4.4 4.2-4.2z"],
  // Two chat bubbles over an empty conversation, the front one with text in it: the back
  // bubble's outline stops where the front one's begins, the way doc.on.doc overlaps.
  "bubble.left.and.text.bubble.right": [
    "M3.8 2.4h3.6a2.2 2.2 0 0 1 2.2 2.2V6.2",
    "M1.6 4.6V7.2a2.2 2.2 0 0 0 2.2 2.2l-1.2 3.2 2.8-3.2h1.6",
    "M9 6.2h3.6a2 2 0 0 1 2 2v1.4a2 2 0 0 1-2 2h-1l1.2 3.2-2.8-3.2h-1a2 2 0 0 1-2-2V8.2a2 2 0 0 1 2-2z",
    "M9.4 8.2h3.2",
    "M9.4 9.8h2",
  ],
};

export interface SymbolProps {
  name: SymbolName;
  /** The size in points; the Mac's marks are 16 pt unless the row says otherwise. */
  size?: number;
  /** The stroke in points, when the Mac draws the mark at another weight: its `.light`
      at 34 pt is thinner than the grid's own 1.5/16 would make it. */
  stroke?: number;
  className?: string;
  /** The Mac's `.help` text, when the mark stands alone in a button. */
  title?: string;
  style?: CSSProperties;
}

/// A symbol, drawn.
export function Symbol({ name, size = 16, stroke, className, title, style }: SymbolProps) {
  const strokeWidth = stroke ?? (1.5 * size) / 16;
  return (
    <svg
      className={className}
      style={style}
      viewBox="0 0 16 16"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      role={title ? "img" : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : "true"}
      focusable="false"
    >
      {PATHS[name].map((path, index) => (
        <path key={index} d={path} />
      ))}
    </svg>
  );
}

/// The folder the Mac draws (FolderIcon.swift:21-66): the closed shape and the open one,
/// on a 16 × 13 grid, with the faint fill of the same ink over the outline.
export function FolderIcon({ open = false, size = 16, className }: { open?: boolean; size?: number; className?: string }) {
  const height = (size * 13) / 16;
  const stroke = size / 11.5;
  const closed = [
    "M1.2 10.7V2.3Q1.2 1.2 2.3 1.2H5.4L6.9 2.7H13.7Q14.8 2.7 14.8 3.8V10.7Q14.8 11.8 13.7 11.8H2.3Q1.2 11.8 1.2 10.7Z",
    "M1.2 4.6h13.6",
  ];
  const opened = [
    "M1.2 11V2.3Q1.2 1.2 2.3 1.2H5.4L6.9 2.7H12.3Q13.4 2.7 13.4 3.8V5.4",
    "M1.2 11L3.2 6.2Q4.2 5.4 5.4 5.4H14.6Q15.2 5.4 15.5 6.2L13.2 11.2Q12.9 11.8 12.2 11.8H2Q1.2 11.8 1.2 11Z",
  ];
  return (
    <svg
      className={className}
      viewBox="0 0 16 13"
      width={size}
      height={height}
      fill="currentColor"
      fillOpacity="0.2"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {(open ? opened : closed).map((path, index) => (
        <path key={index} d={path} fill="none" />
      ))}
    </svg>
  );
}

/// The app's own mark, the `>_` the spinner draws (Spinner.swift:153-177): the chevron and
/// the cursor, on the coordinates of the app's icon.
export const PROMPT_BOX = 690;
export const PROMPT_HEIGHT = 530;
export const PROMPT_CHEVRON = "M77 74L267 262 77 450";
export const PROMPT_CURSOR = "M377 450h230";

/// The mark's stroke, in the box's own units. The Mac draws the mark with a line of
/// `max(1, size × 0.11)` points in a box of `size` points (Spinner.swift:39-42), so the
/// line is a fraction of the box that never falls below a point.
export function promptStroke(size: number): number {
  return Math.max(1, size * 0.11) * (PROMPT_BOX / size);
}
