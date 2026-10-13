// Application shell: navigation, hash routing, shared status, refresh.

import { get } from "./api.js";
import { h, clear, append, icon, fmt, announce } from "./components/ui.js";
import overview from "./pages/overview.js";
import website from "./pages/website.js";
import inventory from "./pages/inventory.js";
import checkout from "./pages/checkout.js";

const PAGES = [
  { id: "overview", label: "Overview", icon: "overview", module: overview },
  { id: "website", label: "Website stock", icon: "website", module: website },
  { id: "inventory", label: "Store stock", icon: "inventory", module: inventory },
  { id: "checkout", label: "Orders & lost sales", icon: "checkout", module: checkout },
];

const els = {
  shell: document.getElementById("shell"),
  nav: document.getElementById("nav"),
  page: document.getElementById("page"),
  main: document.getElementById("main"),
  crumb: document.getElementById("crumb"),
  readAt: document.getElementById("read-at"),
  banner: document.getElementById("global-banner"),
  refresh: document.getElementById("refresh-btn"),
  menu: document.getElementById("menu-btn"),
  scrim: document.getElementById("scrim"),
  sidebar: document.getElementById("sidebar"),
};

// ---------- routing ----------
function parseHash() {
  const raw = location.hash.replace(/^#\/?/, "");
  const [path, qs] = raw.split("?");
  const page = PAGES.find((p) => p.id === path) ? path : "overview";
  const params = Object.fromEntries(new URLSearchParams(qs || ""));
  return { page, params };
}

function buildHash(page, params) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params || {})) if (v !== undefined && v !== null && v !== "") q.set(k, v);
  const s = q.toString();
  return `#/${page}${s ? `?${s}` : ""}`;
}

let current = { page: null, params: {}, controller: null };

const app = {
  status: null,

  navigate(page, params = {}) {
    closeNav();
    const target = buildHash(page, params);
    if (location.hash === target) route();
    else location.hash = target;
  },

  // Change filters/selection on the current page without adding history entries.
  setParams(patch, { replace = true } = {}) {
    const params = { ...current.params, ...patch };
    for (const k of Object.keys(params)) if (params[k] === undefined || params[k] === null || params[k] === "") delete params[k];
    const hash = buildHash(current.page, params);
    if (replace) history.replaceState(null, "", hash);
    else history.pushState(null, "", hash);
    current.params = params;
    current.controller?.update(params);
  },

  params: () => current.params,

  markRead(meta) {
    if (meta?.read_at) els.readAt.textContent = `Updated ${fmt.time(meta.read_at)}`;
  },

  async refreshStatus() {
    try {
      const r = await get("/status");
      app.status = r.data;
      renderBanner();
      return true;
    } catch (err) {
      clear(els.banner).append(h("div", { class: "banner error", role: "alert" },
        h("span", {}, `${err.message}`)));
      return false;
    }
  },

  // Re-read every report on the current page (never runs sync or ETL).
  async refresh() {
    const [okStatus, okPage] = await Promise.all([
      app.refreshStatus(),
      current.controller ? current.controller.reload().then(() => true, () => false) : true,
    ]);
    return okStatus && okPage;
  },
};

function renderBanner() {
  clear(els.banner);
  const q = app.status?.quality;
  if (q?.incomplete) {
    const bits = [];
    if (q.rejected_rows) bits.push(`${q.rejected_rows} source record${q.rejected_rows === 1 ? "" : "s"} rejected by the ETL`);
    if (q.mismatched_pairs) bits.push(`${q.mismatched_pairs} store-product pair${q.mismatched_pairs === 1 ? "" : "s"} differ from the store system`);
    els.banner.append(h("div", { class: "banner warn", role: "status" },
      h("div", {}, h("strong", {}, "Some records are missing from the reports. "),
        `(${bits.join("; ")}).`)));
  }
}

function renderNav() {
  clear(els.nav);
  for (const p of PAGES) {
    els.nav.append(h("li", {},
      h("a", { href: `#/${p.id}`, "aria-current": p.id === current.page ? "page" : undefined },
        icon(p.icon), h("span", {}, p.label))));
  }
}

function route() {
  const { page, params } = parseHash();
  if (current.page === page && current.controller) {
    current.params = params;
    current.controller.update(params);
    return;
  }
  current = { page, params, controller: null };
  const def = PAGES.find((p) => p.id === page);
  renderNav();
  append(clear(els.crumb), [h("span", {}, def.label)]);
  document.title = `${def.label} · PetHaven`;
  clear(els.page);
  const container = h("div");
  els.page.append(container);
  current.controller = def.module.mount(container, app, params);
  els.main.focus({ preventScroll: true });
  window.scrollTo(0, 0);
  announce(`${def.label} page`);
}

// ---------- shell controls ----------
function closeNav() {
  els.shell.classList.remove("nav-open");
  els.scrim.hidden = true;
  els.menu.setAttribute("aria-expanded", "false");
}
els.menu.addEventListener("click", () => {
  const open = !els.shell.classList.contains("nav-open");
  els.shell.classList.toggle("nav-open", open);
  els.scrim.hidden = !open;
  els.menu.setAttribute("aria-expanded", String(open));
  if (open) els.sidebar.querySelector("a")?.focus();
});
els.scrim.addEventListener("click", closeNav);
els.nav.addEventListener("click", (e) => { if (e.target.closest("a")) closeNav(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && els.shell.classList.contains("nav-open")) { closeNav(); els.menu.focus(); } });

els.refresh.addEventListener("click", async () => {
  els.refresh.disabled = true;
  const ok = await app.refresh();
  els.refresh.disabled = false;
  announce(ok ? "Reports refreshed" : "Refresh failed");
});

window.addEventListener("hashchange", route);
app.refreshStatus();
route();
