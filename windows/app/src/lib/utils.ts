// The class names a component's classes are put through, the way shadcn/ui does it: the
// classes that clash are resolved, so a caller's class can win over the component's own.
//
// This is the file AI Elements' components import (upstream: "@/lib/utils").

import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
