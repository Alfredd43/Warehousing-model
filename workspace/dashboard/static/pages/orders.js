// Click & collect orders (UC4, store staff; Report 5): which orders a store must send,
// receive or hand over, most urgent first.

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, errorState, keepFocus } from "../components/ui.js";

const LINE_STATUS = {
  "waiting to be sent": { label: "Waiting to be sent", kind: "warning" },
  "in transit": { label: "In transit", kind: "info" },
  "ready for collection": { label: "Ready for collection", kind: "success" },
};

// Every store table shares these six column widths, so the tables line up
// on the page.
const COLUMN_WIDTHS = ["12%", "19%", "25%", "7%", "17%", "20%"];

// Overdue first, then orders with items still to send, then in transit, then ready.
function urgency(lines) {
  if (lines.some((l) => l.overdue)) return 0;
  if (lines.some((l) => l.line_status === "waiting to be sent")) return 1;
  if (lines.some((l) => l.line_status === "in transit")) return 2;
  return 3;
}

const count = (n, one, many) => `${fmt.num(n)} ${n === 1 ? one : many}`;

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    let res = null, resErr = null, token = 0;

    async function load() {
      const my = ++token;
      resErr = null;
      try {
        const r = await get("/reservations");
        if (my !== token) return;
        res = r;
        app.markRead(r.meta);
      } catch (err) {
        if (my !== token) return;
        resErr = err;
        render();
        throw err;
      }
      render();
    }

    function render() { keepFocus(root, draw); }

    function draw() {
      clear(root);
      root.append(h("div", { class: "page-head" },
        h("div", {}, h("h1", {}, "Click & collect orders"))));
      if (resErr) return root.append(card({ label: "Error", body: errorState(resErr, () => load().catch(() => {})) }));
      if (!res) return root.append(card({ label: "Loading", body: loading() }));

      const all = res.data.rows;
      const stores = res.data.stores;
      const name = (code) => (stores.find((x) => x.store_code === code)?.store_name || code).replace("PetHaven ", "");
      const mine = params.store;
      // rstatus filters item lines; ready and overdue keep or drop whole orders.
      const keep = (r) => (!params.rstatus || r.line_status === params.rstatus) && (!params.overdue || r.overdue)
        && (!params.ready || r.order_ready);
      const any = params.rstatus || params.overdue || params.ready;

      root.append(h("div", { class: "filters", role: "search", "aria-label": "Filter click and collect orders" },
        field("My store", select([{ value: "", label: "All stores" }, ...stores.map((x) => ({ value: x.store_code, label: name(x.store_code) }))],
          mine || "", (v) => app.setParams({ store: v }), { "data-fk": "store" })),
        field("Status", select([{ value: "", label: "All statuses" }, ...Object.entries(LINE_STATUS).map(([v, st]) => ({ value: v, label: st.label }))], params.rstatus || "", (v) => app.setParams({ rstatus: v }), { "data-fk": "rstatus" })),
        h("label", { class: "check" }, h("input", { type: "checkbox", "data-fk": "overdue", checked: !!params.overdue, onchange: (e) => app.setParams({ overdue: e.target.checked ? "1" : "" }) }), "Overdue only"),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ rstatus: "", overdue: "", ready: "" }) }, "Clear filters") : null));

      // A store's work: lines it must send (it is the source) and orders collected there.
      root.append(counts(all.filter((r) => !mine || r.pickup_store_code === mine || r.source_store_code === mine), mine));

      if (!all.length) { root.append(card({ id: "reservations", title: "Open orders", body: state("", "No open orders", "Every click & collect order has been collected or cancelled.") })); return; }

      // One table per pickup store: the orders its customers collect there.
      const pickupStores = mine ? [mine] : stores.map((x) => x.store_code).filter((c) => all.some((r) => r.pickup_store_code === c));
      for (const code of pickupStores) {
        const lines = all.filter((r) => r.pickup_store_code === code && keep(r));
        if (!mine && !lines.length) continue;
        root.append(storeTable({
          id: `orders-${code}`, title: name(code),
          lines, empty: mine ? "No open orders are collected at this store." : "No open lines match these filters.",
          columns: ["Order", "Ordered", "Product", "Units", "Source store", "Status"],
        }));
      }
      // The selected store also sends items for orders collected elsewhere.
      if (mine) {
        const outgoing = all.filter((r) => r.source_store_code === mine && r.pickup_store_code !== mine && keep(r));
        if (outgoing.length) root.append(storeTable({
          id: `send-${mine}`, title: `${name(mine)}: items for other stores`,
          lines: outgoing, empty: "",
          columns: ["Order", "Ordered", "Product", "Units", "Pickup store", "Status"],
        }));
      }
    }

    function storeTable({ id, title, lines, empty, columns }) {
      const byOrder = new Map();
      for (const r of lines) {
        if (!byOrder.has(r.order_no)) byOrder.set(r.order_no, []);
        byOrder.get(r.order_no).push(r);
      }
      const orders = [...byOrder.entries()].sort(([, a], [, b]) =>
        urgency(a) - urgency(b) || new Date(a[0].reserved_at) - new Date(b[0].reserved_at));
      const cell = {
        "Product": (r) => h("td", {}, r.product_name),
        "Units": (r) => h("td", {}, fmt.num(r.units)),
        "Source store": (r) => h("td", {}, r.taken_from.replace("PetHaven ", "")),
        "Pickup store": (r) => h("td", {}, r.pickup_store.replace("PetHaven ", "")),
        "Status": (r) => h("td", {}, badge(LINE_STATUS[r.line_status]?.label || r.line_status, LINE_STATUS[r.line_status]?.kind || "neutral")),
      };
      // One value per order, shown once beside all of its lines. Each line has
      // its own status; only overdue belongs to the whole order.
      const perOrder = {
        "Order": (r, rows) => h("td", { class: "order-cell" }, `Order ${r.order_no}`,
          rows.some((l) => l.overdue) ? h("div", { class: "order-flag" }, badge("Overdue", "danger")) : null),
        "Ordered": (r) => h("td", {}, fmt.dateTime(r.reserved_at)),
      };
      const tbody = h("tbody");
      for (const [, rows] of orders) {
        rows.forEach((r, n) => tbody.append(h("tr", { class: n === 0 ? "order-first" : "" },
          columns.map((c) => {
            if (!perOrder[c]) return cell[c](r);
            if (n > 0) return null;
            const td = perOrder[c](r, rows);
            td.setAttribute("rowspan", String(rows.length));
            return td;
          }))));
      }
      return card({
        id, title,
        body: lines.length ? h("div", { class: "table-wrap" }, h("table", { class: "orders-table" },
          h("caption", { class: "sr-only" }, `${title}: open click-and-collect order lines`),
          h("colgroup", {}, COLUMN_WIDTHS.map((w) => h("col", { style: `width:${w}` }))),
          h("thead", {}, h("tr", {}, columns.map((c) => h("th", { scope: "col" }, c)))),
          tbody)) : state("", empty, ""),
      });
    }

    // ---------- the store's work, in working order ----------
    function counts(rows, mine) {
      const orders = (pred) => new Set(rows.filter(pred).map((r) => r.order_no)).size;
      const toSend = rows.filter((r) => r.line_status === "waiting to be sent" && (!mine || r.source_store_code === mine)).length;
      const inTransit = rows.filter((r) => r.line_status === "in transit" && (!mine || r.pickup_store_code === mine)).length;
      const ready = orders((r) => r.order_ready && (!mine || r.pickup_store_code === mine));
      const overdue = orders((r) => r.overdue && (!mine || r.pickup_store_code === mine));
      // Overdue and ready count whole orders; to send and in transit count item lines.
      const tile = (label, value, tone, patch) => h("button", { class: `kpi ${tone}`, type: "button", onclick: () => app.setParams(patch) },
        h("span", { class: "kpi-label" }, label), h("strong", { class: "kpi-value" }, value));
      return h("div", { class: "kpis kpis-4" },
        tile("Overdue", count(overdue, "order", "orders"), overdue ? "bad" : "good", { overdue: "1", rstatus: "", ready: "" }),
        tile("To send", count(toSend, "item", "items"), toSend ? "warn" : "good", { rstatus: "waiting to be sent", overdue: "", ready: "" }),
        tile("In transit", count(inTransit, "item", "items"), "neutral", { rstatus: "in transit", overdue: "", ready: "" }),
        tile("Ready to collect", count(ready, "order", "orders"), "good", { ready: "1", rstatus: "", overdue: "" }));
    }

    load().catch(() => {});
    return {
      update(next) { params = next; render(); },
      reload: () => load(),
    };
  },
};
