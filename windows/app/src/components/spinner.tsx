// The Mac's loader (Spinner.swift:1-177): the app's own prompt mark, the `>_`, drawing
// itself in short dashes over a faint copy of itself, then fading to start again.
//
// The Mac draws it with Core Animation: two shape layers per part — a faint one, and one
// whose `strokeEnd` grows — so the dashes appear along the path as it is drawn. The chevron
// draws first (over the first 40 % of the round), the cursor next (32 %–60 %), both hold,
// and the mark fades from 78 % to the end. The round is 1.6 s.
//
// Here the same thing is drawn in SVG. The faint copy is always there; the drawn copy is
// the same path with the Mac's dash pattern, revealed along its length by a mask that
// grows — the SVG equivalent of Core Animation's `strokeEnd`.

import { useId } from "react";
import { PROMPT_BOX, PROMPT_CHEVRON, PROMPT_CURSOR, PROMPT_HEIGHT, promptStroke } from "./symbols";

/// The Mac's timings, in fractions of the round (Spinner.swift:33-51).
const CYCLE = 1.6;
const CHEVRON_END = 0.4;
const CURSOR_START = 0.32;
const CURSOR_END = 0.6;
const FADE_START = 0.78;

/// The Mac's ease (Spinner.swift:45-48): the smoothstep, t²(3−2t).
function ease(x: number): number {
  const t = Math.max(0, Math.min(1, x));
  return t * t * (3 - 2 * t);
}

export function Spinner({ size = 11, className }: { size?: number; className?: string }) {
  const id = useId();
  const height = (size * PROMPT_HEIGHT) / PROMPT_BOX;
  const stroke = promptStroke(size);
  // The Mac's dash pattern (Spinner.swift:39-42): a line, then 1.8 lines of space.
  const dash = `${stroke} ${stroke * 1.8}`;
  return (
    <svg
      className={`spinner ${className ?? ""}`}
      viewBox={`0 0 ${PROMPT_BOX} ${PROMPT_HEIGHT}`}
      width={size}
      height={height}
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      role="img"
      aria-label="Working"
    >
      <defs>
        {/* The mask that grows along the path: the drawn part, up to where the Mac's
            `strokeEnd` has reached. `pathLength` makes the dash one unit of the path, so
            the offset is the fraction drawn. */}
        <mask id={`${id}-chevron`} maskUnits="userSpaceOnUse">
          <path
            className="spinner-reveal spinner-reveal-chevron"
            d={PROMPT_CHEVRON}
            stroke="#fff"
            strokeWidth={stroke}
            pathLength={1}
            strokeDasharray="1 1"
          />
        </mask>
        <mask id={`${id}-cursor`} maskUnits="userSpaceOnUse">
          <path
            className="spinner-reveal spinner-reveal-cursor"
            d={PROMPT_CURSOR}
            stroke="#fff"
            strokeWidth={stroke}
            pathLength={1}
            strokeDasharray="1 1"
          />
        </mask>
      </defs>
      {/* The faint copy: the whole mark, always there (Spinner.swift:118-120). */}
      <g className="spinner-faint">
        <path d={PROMPT_CHEVRON} strokeDasharray={dash} />
        <path d={PROMPT_CURSOR} strokeDasharray={dash} />
      </g>
      {/* The drawn copy: the dashes, appearing along each part as the Mac draws it. */}
      <g className="spinner-drawn">
        <path d={PROMPT_CHEVRON} strokeDasharray={dash} mask={`url(#${id}-chevron)`} />
        <path d={PROMPT_CURSOR} strokeDasharray={dash} mask={`url(#${id}-cursor)`} />
      </g>
    </svg>
  );
}

export { CYCLE, CHEVRON_END, CURSOR_START, CURSOR_END, FADE_START, ease };
