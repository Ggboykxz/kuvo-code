// The update check that works with our own releases.
//
// electron-updater's GitHub provider looks for a release the way npm does — the newest
// stable one, with a version tag. Ours are prereleases with a tag of their own
// ("windows-v0.5.33"), so the provider finds nothing and the promise the settings make
// ("Automatic updates") is kept to nothing. The shell asks GitHub itself instead, compares
// the versions, and offers the installer that goes with it.

const RELEASES_API = "https://api.github.com/repos/Ggboykxz/kuvo-code/releases?per_page=30";
const TAG_PREFIX = "windows-v";

/// The three numbers of a version, and nothing else: the pre-release part is ours to
/// ignore, the numbers are what the user reads.
function numbers(value) {
  const match = /^(\d+)\.(\d+)\.(\d+)/.exec(String(value ?? ""));
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

/// Is `candidate` newer than `current`?
function isNewer(candidate, current) {
  const left = numbers(candidate);
  const right = numbers(current);
  if (!left || !right) return false;
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] > right[index];
  }
  return false;
}

/// The release to offer: the newest one of ours that is newer than what is running, and the
/// installer that goes with it. Nothing when there is none.
function pickRelease(releases, current) {
  const ours = (releases ?? []).filter(
    release => !release?.draft && typeof release?.tag_name === "string" && release.tag_name.startsWith(TAG_PREFIX),
  );
  let best = null;
  for (const release of ours) {
    const version = release.tag_name.slice(TAG_PREFIX.length);
    if (!isNewer(version, current)) continue;
    if (best && !isNewer(version, best.version)) continue;
    const assets = release.assets ?? [];
    const asset =
      assets.find(item => item.name === `Kuvo-Code-Setup-${version}.exe`) ??
      assets.find(item => item.name === `Kuvo-Code-${version}.exe`);
    if (!asset) continue;
    best = {
      version,
      url: asset.browser_download_url,
      name: asset.name,
      notes: release.body ?? "",
      publishedAt: release.published_at ?? "",
    };
  }
  return best;
}

module.exports = { RELEASES_API, TAG_PREFIX, isNewer, pickRelease, numbers };
