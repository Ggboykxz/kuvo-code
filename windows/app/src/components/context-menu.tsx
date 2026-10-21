// The right-click menu the Mac shows (RightClickMenu.swift:4-65): a list of items, and a
// separator between them.

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
