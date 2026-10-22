// The right-click menu the Mac shows (RightClickMenu.swift:4-65): a list of items, and a
// separator between them.

import { useEffect } from "react";

export type ContextMenuItem = {
  label: string;
  run?: () => void;
  disabled?: boolean;
  danger?: boolean;
  separator?: boolean;
};

export function ContextMenu({ x, y, items, onClose }: {
  x: number;
  y: number;
  items: ContextMenuItem[];
  onClose: () => void;
}) {
  // A menu on the Mac is dismissed with Escape, and the keys typed after it go back to
  // the thing the menu was opened on. The key is taken in the capture phase: the
  // terminal's own handler stops it from travelling any further, and Escape belongs to
  // the menu that is open, not to the shell underneath it.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      onClose();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);

  return (
    <div className="context-menu" style={{ left: x, top: y }} role="menu" onMouseLeave={onClose}>
      {items.map((item, index) => item.separator ? (
        <hr key={`separator_${index}`} className="menu-separator" role="separator" />
      ) : (
        <button
          key={item.label}
          role="menuitem"
          disabled={item.disabled}
          className={item.danger ? "danger" : undefined}
          onClick={() => { onClose(); item.run?.(); }}
        >{item.label}</button>
      ))}
    </div>
  );
}
