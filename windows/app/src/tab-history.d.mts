export declare const MAX_CLOSED_TABS: number;
export declare function rememberClosed(
  closed: { id: string; index: number }[],
  entries: { id: string; index: number }[],
): { id: string; index: number }[];
export declare function takeClosed(
  closed: { id: string; index: number }[],
  open: string[],
  exists: (id: string) => boolean,
): { entry: { id: string; index: number } | null; closed: { id: string; index: number }[] };
export declare function tabAfterClose(tabs: string[], index: number): string | null;
export declare function cycledTab(tabs: string[], current: string | null, step: number): string | null;
export declare function tabAt(tabs: string[], number: number): string | null;
