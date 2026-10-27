// A destructive action that asks where it is, not in a system dialog over the page: the
// button becomes Keep and the action's own word, Keep takes the focus first, and Escape
// or moving the focus away leaves things as they were. The Mac's Pressable rows do the
// same, and the session row already did; this is the shared version for everywhere else.

import { type ReactNode, useEffect, useRef, useState } from "react";

export function ConfirmAction({ question, confirmLabel, onConfirm, className = "small", title, ariaLabel, children }: {
  /// What is being asked, for a screen reader and the group's label.
  question: string;
  /// The action's own word, in the danger colour: "Revert", "Remove", "Delete".
  confirmLabel: string;
  onConfirm: () => void | Promise<void>;
  /// The trigger's own classes, so it keeps the weight of the row it sits in.
  className?: string;
  title?: string;
  /// For an icon-only trigger, where the mark is not words.
  ariaLabel?: string;
  children?: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const restore = useRef(false);

  // Keep and Escape put the hand back on the button it came from, so the keyboard does
  // not start over at the top of the page.
  useEffect(() => {
    if (!open && restore.current) {
      restore.current = false;
      trigger.current?.focus();
    }
  }, [open]);

  const cancel = () => {
    restore.current = true;
    setOpen(false);
  };

  if (!open) {
    return (
      <button
        ref={trigger}
        type="button"
        className={className}
        title={title}
        aria-label={ariaLabel}
        aria-expanded={false}
        onClick={() => setOpen(true)}
      >
        {children}
      </button>
    );
  }

  return (
    <span
      className="confirm-action"
      role="group"
      aria-label={question}
      title={question}
      onBlur={event => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) cancel();
      }}
      onKeyDown={event => {
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          cancel();
        }
      }}
    >
      <button type="button" className="confirm-keep" autoFocus onClick={cancel}>Keep</button>
      <button
        type="button"
        className="confirm-yes"
        onClick={() => {
          setOpen(false);
          void onConfirm();
        }}
      >
        {confirmLabel}
      </button>
    </span>
  );
}
