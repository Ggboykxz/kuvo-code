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
  | "chevron.right"
  | "chevron.down"
  | "chevron.up"
  | "arrow.down"
  | "arrow.up"
  | "arrow.clockwise"
  | "tray.and.arrow.down"
  | "list.bullet"
  | "doc"
  | "magnifyingglass"
  | "arrow.triangle.branch"
  | "arrow.uturn.backward"
  | "square.and.pencil";

/// The paths, on the 16 pt grid, in the Mac's own order.
const PATHS: Record<SymbolName, string[]> = {
  "xmark": ["M4 4l8 8", "M12 4l-8 8"],
  "chevron.right": ["M6.5 3.5L10.5 8l-4 4.5"],
  "chevron.down": ["M3.5 6.5L8 10.5l4.5-4"],
  "chevron.up": ["M3.5 9.5L8 5.5l4.5 4"],
  "arrow.down": ["M8 3v9.5", "M4.5 9L8 12.5 11.5 9"],
  "arrow.up": ["M8 13V3.5", "M4.5 7L8 3.5 11.5 7"],
  "arrow.clockwise": ["M4 9.5A4.5 4.5 0 1 1 12 8", "M12 8l-2-1.6", "M12 8l2-1.6"],
  "tray.and.arrow.down": ["M2.5 9.5v3h11v-3", "M8 2.5v5", "M5.5 5L8 7.5 10.5 5"],
  "list.bullet": ["M6 4.2h7.5", "M6 8h7.5", "M6 11.8h7.5", "M3 4.2h.01", "M3 8h.01", "M3 11.8h.01"],
  "doc": ["M4 2.6h5l3 3v7.8H4z", "M9 2.6v3h3"],
  "magnifyingglass": ["M7 2.6a4.4 4.4 0 1 0 0 8.8 4.4 4.4 0 0 0 0-8.8Z", "M10.4 10.4L13.4 13.4"],
  "arrow.triangle.branch": ["M5.2 2.6v7.2a2.6 2.6 0 0 0 2.6 2.6h4.4", "M5.2 2.6L2.6 5.2M5.2 2.6l2.6 2.6", "M11 9.6h1.2a1.4 1.4 0 0 0 1.4-1.4V4.4", "M11 9.6L9.4 8M11 9.6l1.6-1.6"],
  "arrow.uturn.backward": ["M4 6.6h5.4a3.4 3.4 0 0 1 0 6.8H6.6", "M6.6 3.6L3.4 6.6l3.2 3"],
  "square.and.pencil": ["M9.2 3.2h3.6v3.6", "M9.4 6.4L4.2 11.6l-2 .6.6-2 .4.6.6-2-1.4.4 4.2-4.2z"],
};

export interface SymbolProps {
  name: SymbolName;
  /** The size in points; the Mac's marks are 16 pt unless the row says otherwise. */
  size?: number;
  className?: string;
  /** The Mac's `.help` text, when the mark stands alone in a button. */
  title?: string;
  style?: CSSProperties;
}

/// A symbol, drawn.
export function Symbol({ name, size = 16, className, title, style }: SymbolProps) {
  const stroke = (1.5 * size) / 16;
  return (
    <svg
      className={className}
      style={style}
      viewBox="0 0 16 16"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
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
export function PromptMark({ size = 11, className }: { size?: number; className?: string }) {
  const height = (size * 530) / 690;
  const stroke = Math.max(0.9, size / 9);
  return (
    <svg
      className={className}
      viewBox="0 0 690 530"
      width={size}
      height={height}
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M77 74L267 262 77 450" />
      <path d="M377 450h230" />
    </svg>
  );
}
