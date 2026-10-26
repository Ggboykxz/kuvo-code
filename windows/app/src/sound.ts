// The interface's own sounds, made here with the Web Audio API rather than shipped as
// files: nothing to download, nothing to license, and nothing to fetch at runtime.
//
// The setting starts off. A cue is a short, quiet pair of notes — enough to tell you a
// run finished while you were looking elsewhere, never enough to interrupt.

export type Cue = "send" | "done" | "error" | "copy";

type Note = {
  /** Seconds after the cue starts. */
  at: number;
  hz: number;
  ms: number;
  gain: number;
  type?: OscillatorType;
};

let enabled = false;
let context: AudioContext | null = null;

export function setSoundEnabled(on: boolean) {
  enabled = on;
  if (!on && context) {
    void context.close().catch(() => {});
    context = null;
  }
}

const CUES: Record<Cue, Note[]> = {
  // Sent: a small step up, like a key leaving the keyboard.
  send: [
    { at: 0, hz: 660, ms: 70, gain: 0.05 },
    { at: 0.055, hz: 880, ms: 90, gain: 0.045 },
  ],
  // Finished: three notes that settle upward.
  done: [
    { at: 0, hz: 523.25, ms: 90, gain: 0.045 },
    { at: 0.09, hz: 659.25, ms: 90, gain: 0.045 },
    { at: 0.18, hz: 783.99, ms: 150, gain: 0.04 },
  ],
  // Something failed: two low notes that fall.
  error: [
    { at: 0, hz: 233.08, ms: 110, gain: 0.05, type: "triangle" },
    { at: 0.1, hz: 185, ms: 150, gain: 0.045, type: "triangle" },
  ],
  // Copied: one high tick, the quietest of them.
  copy: [{ at: 0, hz: 1244.51, ms: 45, gain: 0.03 }],
};

export function playSound(cue: Cue) {
  if (!enabled) return;
  try {
    const Audio = window.AudioContext;
    if (!Audio) return;
    context ??= new Audio();
    if (context.state === "suspended") void context.resume();
    const start = context.currentTime + 0.01;
    for (const note of CUES[cue]) {
      const oscillator = context.createOscillator();
      const gain = context.createGain();
      oscillator.type = note.type ?? "sine";
      oscillator.frequency.value = note.hz;
      const at = start + note.at;
      const end = at + note.ms / 1000;
      gain.gain.setValueAtTime(0.0001, at);
      gain.gain.exponentialRampToValueAtTime(note.gain, at + 0.012);
      gain.gain.exponentialRampToValueAtTime(0.0001, end);
      oscillator.connect(gain).connect(context.destination);
      oscillator.start(at);
      oscillator.stop(end + 0.02);
    }
  } catch {
    // A machine with no audio output is not a failure worth reporting.
  }
}
