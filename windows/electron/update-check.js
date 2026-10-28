// The update check that works with our own releases.
//
// electron-updater's GitHub provider looks for a release the way npm does — the newest
// stable one, with a version tag. Ours are prereleases with a tag of their own
// ("windows-v0.5.33"), so the provider finds nothing and the promise the settings make
// ("Automatic updates") is kept to nothing. The shell asks GitHub itself instead, compares
// the versions, and offers the installer that goes with it.
//
// Two ways to ask: the API, which lists the assets, and the releases feed, which needs no
// token and has no hourly limit. The feed is the fallback, so a machine whose network has
// used up GitHub's limit for the hour still hears about a new version. The installer's
// name is ours, so the feed's tag is enough to know where it is.

const REPO = "Ggboykxz/kuvo-code";
const RELEASES_API = `https://api.github.com/repos/${REPO}/releases?per_page=30`;
const RELEASES_ATOM = `https://github.com/${REPO}/releases.atom`;
const TAG_PREFIX = "windows-v";

const installerName = version => `Kuvo-Code-Setup-${version}.exe`;
const portableName = version => `Kuvo-Code-${version}.exe`;

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
      assets.find(item => item.name === installerName(version)) ??
      assets.find(item => item.name === portableName(version));
    if (!asset) continue;
    best = {
      version,
      tag: release.tag_name,
      url: asset.browser_download_url,
      name: asset.name,
      notes: release.body ?? "",
      publishedAt: release.published_at ?? "",
    };
  }
  return best;
}

/// Where an asset of a release lives, for the feed's entries, which don't list assets.
function downloadUrl(tag, name) {
  return `https://github.com/${REPO}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`;
}

/// The releases feed, read into the shape `pickRelease` takes. Its entries are the ten most
/// recent releases, each with a tag and a date; the installer is named after the tag.
function parseAtom(xml) {
  const entries = [];
  const pattern = /<entry>([\s\S]*?)<\/entry>/g;
  let found;
  while ((found = pattern.exec(String(xml ?? "")))) {
    const entry = found[1];
    const tag = /<id>tag:github\.com,2008:Repository\/\d+\/([^<]+)<\/id>/.exec(entry)?.[1];
    if (!tag || !tag.startsWith(TAG_PREFIX)) continue;
    const version = tag.slice(TAG_PREFIX.length);
    const updated = /<updated>([^<]+)<\/updated>/.exec(entry)?.[1] ?? "";
    const name = installerName(version);
    entries.push({
      tag_name: tag,
      draft: false,
      published_at: updated,
      body: "",
      assets: [{ name, browser_download_url: downloadUrl(tag, name) }],
    });
  }
  return entries;
}

/// What to tell the user when a check or a download fails. The network's own words are
/// usually about sockets; these say what happened and what to do about it.
function describeError(error) {
  const message = String(error?.message ?? error ?? "").trim();
  if (!message) return "Something went wrong.";
  if (/GitHub answered 403/.test(message)) {
    return "GitHub is limiting requests from this network. Try again in a little while.";
  }
  if (/GitHub answered 404/.test(message)) {
    return "The release could not be found on GitHub.";
  }
  if (/GitHub answered 5\d\d/.test(message)) {
    return "GitHub had a problem answering. Try again in a little while.";
  }
  if (/fetch failed|ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENETUNREACH|certificate|self-signed|UNABLE_TO_VERIFY/i.test(message)) {
    return "Kuvo Code couldn't reach GitHub. Check this computer's connection, proxy or firewall, and try again.";
  }
  return message;
}

module.exports = {
  REPO,
  RELEASES_API,
  RELEASES_ATOM,
  TAG_PREFIX,
  installerName,
  portableName,
  downloadUrl,
  parseAtom,
  describeError,
  isNewer,
  pickRelease,
  numbers,
};
