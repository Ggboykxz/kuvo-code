// The model's own words: the name of the effort a model is asked for.
//
// Plain ESM with no imports, so the browser and the tests load the same copy.

/// The effort's own name, as the Mac names it (ModelPicker.swift:5-14): "xhigh" is
/// "Extra", "max" is "Max", "off" is "Off", and the rest is the level's own name with
/// its first letter up.
export function effortTitle(id) {
  switch (String(id).toLowerCase()) {
    case "xhigh":
    case "x-high":
    case "extra-high":
    case "extra_high":
    case "extrahigh": return "Extra";
    case "max":
    case "maximum": return "Max";
    case "none":
    case "off": return "Off";
    default: return String(id).slice(0, 1).toUpperCase() + String(id).slice(1);
  }
}
