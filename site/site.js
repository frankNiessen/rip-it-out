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

  const macs = document.querySelectorAll('[data-dl="mac"]'), wins = document.querySelectorAll('[data-dl="win"]');
  if (!macs.length && !wins.length) return;

  // Windows visitors see the Windows button first.
  if (/Windows/i.test(navigator.userAgent)) {
    document.querySelectorAll(".downloads").forEach((row) => {
      const mac = row.querySelector('[data-dl="mac"]'), win = row.querySelector('[data-dl="win"]');
      if (!mac || !win) return;
      mac.classList.add("second"); win.classList.remove("second");
      row.insertBefore(win, mac);
    });
  }

  fetch("https://api.github.com/repos/" + repo + "/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((rel) => {
      const find = (re) => (rel.assets || []).find((a) => re.test(a.name));
      const dmg = find(/^RipItOut-[\d.]+\.dmg$/), exe = find(/^RipItOut-Setup-[\d.]+\.exe$/);
      if (dmg) macs.forEach((a) => { a.href = dmg.browser_download_url; });
      if (exe) wins.forEach((a) => { a.href = exe.browser_download_url; });
      const line = document.getElementById("release-line");
      if (line && rel.tag_name) {
        line.innerHTML = "Free. Version " + rel.tag_name.replace(/^v/, "") +
          ' · <a href="' + rel.html_url + '">What\'s new</a>';
      }
    })
    .catch(() => {});
})();
