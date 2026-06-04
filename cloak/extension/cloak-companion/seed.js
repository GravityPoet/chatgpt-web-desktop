// ISOLATED world, document_start. Keeps the page-origin localStorage seed
// (__cl_tz) in sync with the chosen zone in chrome.storage, so the MAIN-world
// apply.js can spoof synchronously at document_start on the next load. Runs in
// the isolated world (the only one with chrome.storage), sharing the page's DOM
// and origin localStorage.
try {
  chrome.storage.local.get("tz", function (r) {
    try {
      var tz = r && r.tz;
      if (tz) {
        if (localStorage.getItem("__cl_tz") !== tz) localStorage.setItem("__cl_tz", tz);
      } else {
        localStorage.removeItem("__cl_tz");
      }
    } catch (_) { /* storage blocked on this origin: ignore */ }
  });
} catch (_) { /* no chrome.storage here: ignore */ }
