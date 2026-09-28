// The download buttons point at the newest release's files (their names carry the
// version), found through GitHub's API; without it they open the release page.
(function () {
  const repo = "frankNiessen/rip-it-out";
  // Where tips go (Ko-fi). Empty: the tip section and links stay hidden.
  const TIP_URL = "https://ko-fi.com/frankniessen";
  if (TIP_URL) {
    document.querySelectorAll("[data-tip]").forEach((a) => { a.href = TIP_URL; });
    document.querySelectorAll("#support, [data-tip-wrap]").forEach((el) => { el.hidden = false; });
  }
  const mb = (bytes) => Math.round(bytes / 1e6) + " MB";
  fetch("https://api.github.com/repos/" + repo + "/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((rel) => {
      const version = (rel.tag_name || "").replace(/^v/, "");
      const find = (re) => (rel.assets || []).find((a) => re.test(a.name));
      const mac = find(/^RipItOut-[\d.]+\.dmg$/);
      const win = find(/^RipItOut-Setup-[\d.]+\.exe$/);
      const set = (id, asset, base) => {
        const a = document.getElementById(id);
        if (!a || !asset) return;
        a.href = asset.browser_download_url;
        a.querySelector("[data-meta]").textContent = base + " · " + mb(asset.size);
      };
      set("dl-mac", mac, "Apple Silicon · macOS 13+");
      set("dl-win", win, "Windows 10 and 11 · preview");
      const text = (id, value) => { const el = document.getElementById(id); if (el && value) el.textContent = value; };
      text("mac-file", mac && mac.name);
      text("win-file", win && win.name);
      const date = rel.published_at ? new Date(rel.published_at).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" }) : "";
      const line = document.getElementById("release-line");
      if (line) line.innerHTML =
        "Version " + version + (date ? " · " + date : "") + " · free and open source (MIT) · " +
        '<a href="' + rel.html_url + '">release notes</a>';
    })
    .catch(() => {});

  // Windows visitors see the Windows button first.
  const macBtn = document.getElementById("dl-mac"), winBtn = document.getElementById("dl-win");
  if (macBtn && winBtn && /Windows/i.test(navigator.userAgent)) {
    const mac = macBtn, win = winBtn;
    mac.classList.add("second"); win.classList.remove("second");
    win.parentNode.insertBefore(win, mac);
  }

  // The counter counts in, like the app before a take.
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) return;
  const num = document.getElementById("lcd-num"), bar = document.getElementById("lcd-bar");
  if (!num) return;
  const beats = [...document.querySelectorAll("#lcd-beats i")];
  let n = 0;
  setInterval(() => {
    const beat = n % 4, b = Math.floor(n / 4);
    num.textContent = beat + 1;
    num.style.color = beat === 0 ? "var(--lcd-ink)" : "#9fbf38";
    bar.textContent = b === 0 ? "Count-in" : "Bar " + b;
    beats.forEach((el, i) => el.classList.toggle("on", i === beat));
    n = (n + 1) % 36;
  }, 60000 / 120);
})();
