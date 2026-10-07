// Small DOM and formatting helpers. Data is always inserted as text, never as HTML.

export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = v;
    else if (k === "dataset") Object.assign(el.dataset, v);
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === "value") el.value = v;
    else if (k === "checked") el.checked = !!v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  append(el, children);
  return el;
}

export function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c === undefined || c === null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

export function clear(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
  return el;
}

// ---------- icons (local, outline) ----------
const ICONS = {
  website: "M3 5h18v12H3zM8 21h8M12 17v4",
  inventory: "M3 7l9-4 9 4-9 4-9-4zM3 7v10l9 4 9-4V7M12 11v10",
  checkout: "M6 6h15l-2 9H8L6 3H3M9 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2zM18 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2z",
  integration: "M4 6h6v4H4zM14 14h6v4h-6zM7 10v4a2 2 0 0 0 2 2h5M17 14v-4a2 2 0 0 0-2-2h-5",
  arrow: "M5 12h14M13 6l6 6-6 6",
  overview: "M4 4h7v7H4zM13 4h7v4h-7zM13 10h7v10h-7zM4 13h7v7H4z",
  sync: "M20 11a8 8 0 0 0-14.3-4.9L4 8M4 4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16M20 20v-4h-4",
  close: "M6 6l12 12M18 6L6 18",
};

export function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", ICONS[name] || "");
  svg.append(path);
  return svg;
}

// ---------- formatting (Australia/Sydney) ----------
const TZ = "Australia/Sydney";
const dtFmt = new Intl.DateTimeFormat("en-AU", {
  timeZone: TZ, day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit",
});
const dtSecFmt = new Intl.DateTimeFormat("en-AU", {
  timeZone: TZ, day: "numeric", month: "short", hour: "numeric", minute: "2-digit", second: "2-digit",
});
const dFmt = new Intl.DateTimeFormat("en-AU", { timeZone: TZ, day: "numeric", month: "short", year: "numeric" });
const nFmt = new Intl.NumberFormat("en-AU");

export const fmt = {
  dateTime: (iso) => (iso ? dtFmt.format(new Date(iso)) : "—"),
  dateTimeSec: (iso) => (iso ? dtSecFmt.format(new Date(iso)) : "—"),
  // Business dates arrive as YYYY-MM-DD: format without shifting the day.
  date: (d) => (d ? dFmt.format(new Date(`${d}T12:00:00+10:00`)) : "—"),
  num: (n) => (n === null || n === undefined ? "—" : nFmt.format(n)),
  signed: (n) => {
    if (n === null || n === undefined) return "—";
    if (n > 0) return `+${nFmt.format(n)}`;
    if (n < 0) return `−${nFmt.format(Math.abs(n))}`;
    return "0";
  },
  ago: (iso) => {
    if (!iso) return "";
    const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
    if (s < 60) return "just now";
    const m = Math.round(s / 60);
    if (m < 60) return `${m} min ago`;
    const hrs = Math.floor(m / 60);
    if (hrs < 48) return `${hrs} h ${m % 60} min ago`;
    return `${Math.floor(hrs / 24)} days ago`;
  },
  units: (n) => `${nFmt.format(n)} unit${Math.abs(n) === 1 ? "" : "s"}`,
  time: (iso) => (iso ? new Intl.DateTimeFormat("en-AU", { timeZone: TZ, hour: "numeric", minute: "2-digit" }).format(new Date(iso)) : "—"),
};

// "3 min", "1 min 05 s", "40 s"
export function duration(totalSeconds) {
  const s = Math.max(0, Math.round(totalSeconds));
  const m = Math.floor(s / 60);
  const r = s % 60;
  if (!m) return `${r} s`;
  return r ? `${m} min ${String(r).padStart(2, "0")} s` : `${m} min`;
}

export function countdown(iso) {
  if (!iso) return "—";
  const s = (new Date(iso).getTime() - Date.now()) / 1000;
  return s > 0 ? duration(s) : "due now";
}

export const SYNC_TRIGGER = { scheduled: "automatic", manual: "manual", seed: "sample data" };

// Every second: refresh [data-until] countdowns and [data-ago] times inside
// root, and shortly after a scheduled sync is due re-read the reports (never
// runs a sync; the scheduler does). getSchedule() returns the latest
// {scheduler_status, next_sync_at}.
export function syncTicker(root, app, getSchedule) {
  let rereadFor = null;
  const timer = setInterval(() => {
    if (!root.isConnected) { clearInterval(timer); return; }
    root.querySelectorAll("[data-until]").forEach((el) => { el.textContent = countdown(el.dataset.until); });
    root.querySelectorAll("[data-ago]").forEach((el) => { el.textContent = fmt.ago(el.dataset.ago); });
    const s = getSchedule();
    const due = s?.scheduler_status === "running" && s.next_sync_at;
    if (due && Date.now() - new Date(due).getTime() > 1500 && rereadFor !== due) {
      rereadFor = due;
      app.refresh();
    }
  }, 1000);
}

// ---------- building blocks ----------
export function badge(text, kind = "neutral", { dot = true } = {}) {
  return h("span", { class: `badge b-${kind}${dot ? "" : " plain"}` }, text);
}

export function card({ title, subtitle, actions, body, foot, id, label } = {}) {
  const headingId = id ? `${id}-title` : undefined;
  return h("section", { class: "card", id, "aria-labelledby": headingId, "aria-label": headingId ? undefined : label },
    title || actions ? h("div", { class: "card-head" },
      h("div", {}, title ? h("h2", { id: headingId }, title) : null, subtitle ? h("p", {}, subtitle) : null),
      actions ? h("div", { class: "filters", style: "margin:0" }, actions) : null) : null,
    body,
    foot ? h("div", { class: "card-foot" }, foot) : null);
}

export function state(kind, title, text, action) {
  return h("div", { class: `state ${kind || ""}`, role: kind === "error" ? "alert" : undefined },
    h("strong", {}, title), text ? h("p", {}, text) : null,
    action ? h("div", { style: "margin-top:12px" }, action) : null);
}

export function loading(label = "Loading") {
  return h("div", { class: "card-body", "aria-busy": "true" },
    h("span", { class: "sr-only" }, label),
    h("div", { class: "skeleton", style: "width:60%" }), h("div", { class: "skeleton" }),
    h("div", { class: "skeleton", style: "width:80%" }));
}

export function field(label, control, { wide = false, hint } = {}) {
  return h("label", { class: `field${wide ? " wide" : ""}` }, h("span", {}, label), control,
    hint ? h("small", { class: "muted" }, hint) : null);
}

export function select(options, value, onChange, attrs = {}) {
  const el = h("select", attrs,
    options.map((o) => h("option", { value: o.value, selected: String(o.value) === String(value ?? "") }, o.label)));
  if (onChange) el.addEventListener("change", () => onChange(el.value));
  return el;
}

export function segmented(label, options, value, onChange) {
  return h("div", { class: "field seg" }, h("span", { id: `seg-${label.replace(/\W/g, "")}` }, label),
    h("div", { class: "segmented", role: "group", "aria-labelledby": `seg-${label.replace(/\W/g, "")}` },
      options.map((o) => h("button", {
        type: "button", "aria-pressed": String(o.value === value), "data-fk": `seg-${label}-${o.value}`,
        onclick: () => onChange(o.value),
      }, o.label))));
}

/**
 * Accessible data table.
 * columns: [{key, label, num, render(row) -> Node|string, sub(row)}]
 */
export function table({ columns, rows, caption, rowKey, selectedKey, onSelect, empty, rowClass }) {
  if (!rows.length) return empty || state("", "No rows", "");
  const tbody = h("tbody");
  for (const r of rows) {
    const key = rowKey ? rowKey(r) : undefined;
    const selected = key !== undefined && key === selectedKey;
    const tr = h("tr", {
      class: [onSelect ? "clickable" : "", selected ? "selected" : "", rowClass ? rowClass(r) : ""].join(" ").trim(),
      tabindex: onSelect ? "0" : undefined,
      "data-fk": onSelect && key !== undefined ? `row-${key}` : undefined,
      "aria-selected": onSelect ? String(selected) : undefined,
    });
    if (onSelect) {
      tr.addEventListener("click", (e) => { if (!e.target.closest("a,button")) onSelect(r); });
      tr.addEventListener("keydown", (e) => {
        if ((e.key === "Enter" || e.key === " ") && e.target === tr) { e.preventDefault(); onSelect(r); }
      });
    }
    for (const c of columns) {
      const content = c.render ? c.render(r) : r[c.key];
      tr.append(h("td", { class: c.num ? "num" : "" },
        content === null || content === undefined ? "—" : content,
        c.sub ? h("span", { class: "cell-sub" }, c.sub(r)) : null));
    }
    tbody.append(tr);
  }
  return h("div", { class: "table-wrap" },
    h("table", {},
      caption ? h("caption", { class: "sr-only" }, caption) : null,
      h("thead", {}, h("tr", {}, columns.map((c) => h("th", { scope: "col", class: c.num ? "num" : "" }, c.label)))),
      tbody));
}

export function pager(page, onPage) {
  const { total, limit, offset } = page;
  if (total <= limit) return h("div", { class: "pager" }, `${fmt.num(total)} row${total === 1 ? "" : "s"}`);
  const from = total ? offset + 1 : 0;
  const to = Math.min(offset + limit, total);
  return h("div", { class: "pager" },
    `${fmt.num(from)}–${fmt.num(to)} of ${fmt.num(total)}`,
    h("button", { class: "btn btn-small", type: "button", disabled: offset === 0 || undefined,
      onclick: () => onPage(Math.max(0, offset - limit)) }, "Previous"),
    h("button", { class: "btn btn-small", type: "button", disabled: to >= total || undefined,
      onclick: () => onPage(offset + limit) }, "Next"));
}

export function tabs(items, active, onChange, label) {
  return h("div", { class: "tabs", role: "tablist", "aria-label": label },
    items.map((t) => h("button", {
      type: "button", role: "tab", "aria-selected": String(t.value === active), "data-fk": `tab-${t.value}`,
      onclick: () => onChange(t.value),
    }, t.label)));
}

export function kv(pairs) {
  return h("dl", { class: "kv" }, pairs.filter(Boolean).map(([k, v]) => [h("dt", {}, k), h("dd", {}, v ?? "—")]));
}

export function errorState(err, retry) {
  const title = err.status === 503 || err.code === "disconnected" ? "Database or server unavailable" : "Could not load this report";
  return state("error", title, err.message,
    retry ? h("button", { class: "btn", type: "button", onclick: retry }, "Retry") : null);
}

// Re-render a region without losing keyboard focus: controls carry a stable
// data-fk key; the focused one (and its caret) is restored after rendering.
export function keepFocus(root, render) {
  const active = document.activeElement;
  const key = active && root.contains(active) ? active.dataset.fk : null;
  const caret = key && typeof active.selectionStart === "number" ? [active.selectionStart, active.selectionEnd] : null;
  render();
  if (!key) return;
  const next = root.querySelector(`[data-fk="${CSS.escape(key)}"]`);
  if (next) {
    next.focus({ preventScroll: true });
    if (caret && typeof next.setSelectionRange === "function") {
      try { next.setSelectionRange(...caret); } catch { /* not a text input */ }
    }
  }
}

export function announce(text) {
  const el = document.getElementById("announcer");
  el.textContent = "";
  setTimeout(() => { el.textContent = text; }, 30);
}
