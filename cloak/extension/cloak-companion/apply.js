// MAIN world, document_start, runs right after spoof.js. Applies the spoof
// synchronously from the localStorage seed maintained by seed.js — this is the
// race-free path: it does NOT depend on the (cold-start-asleep) service worker.
try {
  var tz = localStorage.getItem("__cl_tz");
  var fpSeed = window.__cloakAccountSeed || localStorage.getItem("__cl_fp_seed");
  if ((tz || fpSeed) && window.__cloakSpoof) window.__cloakSpoof(tz, fpSeed);
} catch (_) { /* restricted origin or no storage: ignore */ }
