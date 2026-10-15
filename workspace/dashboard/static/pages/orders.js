// Click & collect orders (UC4, store staff; Report 5): which orders a store must send,
// receive or hand over, most urgent first.

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, errorState, keepFocus } from "../components/ui.js";

const LINE_STATUS = {
  "waiting to be sent": { label: "Waiting to be sent", kind: "warning" },
  "in transit": { label: "In transit", kind: "info" },
  "ready for collection": { label: "Ready for collection", kind: "success" },
};

// Every store table shares these eight column widths, so the tables line up
// on the page; a table with fewer columns leaves the last slots empty.
const COLUMN_WIDTHS = ["9%", "19%", "18%", "6%", "15%", "14%", "10%", "9%"];

// Overdue first, then orders with items still to send, then in transit, then ready.
function urgency(lines) {
  if (lines.some((l) => l.overdue)) return 0;
  if (lines.some((l) => l.line_status === "waiting to be sent")) return 1;
  if (lines.some((l) => l.line_status === "in transit")) return 2;
  return 3;
}

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
        h("div", {},
          h("h1", {}, "Click & collect orders"),
          h("p", { class: "subtitle" }, "Orders your store must send, receive or hand over, most urgent first."))));
      if (resErr) return root.append(card({ label: "Error", body: errorState(resErr, () => load().catch(() => {})) }));
      if (!res) return root.append(card({ label: "Loading", body: loading() }));

      const all = res.data.rows;
      const stores = res.data.stores;
      const name = (code) => (stores.find((x) => x.store_code === code)?.store_name || code).replace("PetHaven ", "");
      const mine = params.store;
      const keep = (r) => (!params.rstatus || r.line_status === params.rstatus) && (!params.overdue || r.overdue);
      const any = params.rstatus || params.overdue;

      root.append(h("div", { class: "filters", role: "search", "aria-label": "Filter click and collect orders" },
        field("My store", select([{ value: "", label: "All stores" }, ...stores.map((x) => ({ value: x.store_code, label: `${x.store_code} · ${name(x.store_code)}` }))],
          mine || "", (v) => app.setParams({ store: v }), { "data-fk": "store" })),
        field("Line status", select([{ value: "", label: "All statuses" }, ...Object.entries(LINE_STATUS).map(([v, st]) => ({ value: v, label: st.label }))], params.rstatus || "", (v) => app.setParams({ rstatus: v }), { "data-fk": "rstatus" })),
        h("label", { class: "check" }, h("input", { type: "checkbox", "data-fk": "overdue", checked: !!params.overdue, onchange: (e) => app.setParams({ overdue: e.target.checked ? "1" : "" }) }), "Overdue only"),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ rstatus: "", overdue: "" }) }, "Clear filters") : null));

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
          subtitle: (n, l) => `${n} order${n === 1 ? "" : "s"} to collect here (${l} item line${l === 1 ? "" : "s"}), most urgent first.`,
          lines, empty: mine ? "No open orders are collected at this store." : "No open lines match these filters.",
          columns: ["Order", "Ordered", "Product", "Units", "Source store", "Line status", "Order ready", "Overdue"],
        }));
      }
      // The selected store also sends items for orders collected elsewhere.
      if (mine) {
        const outgoing = all.filter((r) => r.source_store_code === mine && r.pickup_store_code !== mine && keep(r));
        if (outgoing.length) root.append(storeTable({
          id: `send-${mine}`, title: `${name(mine)}: items for other stores`,
          subtitle: (n, l) => `${l} item line${l === 1 ? "" : "s"} for ${n} order${n === 1 ? "" : "s"} collected at another store.`,
          lines: outgoing, empty: "",
          columns: ["Order", "Ordered", "Product", "Units", "Pickup store", "Line status"],
        }));
      }
      root.append(h("p", { class: "table-note" },
        "Overdue = the whole order has been ready for more than 3 days and the customer has not collected it; the 3 days start when the last item is ready, so a late transfer never makes an order overdue. Items from another store go: waiting to be sent → in transit → ready for collection. Ordered = when the customer paid and the items were held. Orders are identified by order number; no customer names are stored."));
    }

    function storeTable({ id, title, subtitle, lines, empty, columns }) {
      const byOrder = new Map();
      for (const r of lines) {
        if (!byOrder.has(r.order_no)) byOrder.set(r.order_no, []);
        byOrder.get(r.order_no).push(r);
      }
      const orders = [...byOrder.entries()].sort(([, a], [, b]) =>
        urgency(a) - urgency(b) || new Date(a[0].reserved_at) - new Date(b[0].reserved_at));
      const cell = {
        "Product": (r) => h("td", {}, r.product_name, h("span", { class: "cell-sub" }, r.product_code)),
        "Units": (r) => h("td", {}, fmt.num(r.units)),
        "Source store": (r) => h("td", {}, r.taken_from.replace("PetHaven ", ""), h("span", { class: "cell-sub" }, r.is_transfer ? "Transfer to this store" : "Same store")),
        "Pickup store": (r) => h("td", {}, r.pickup_store.replace("PetHaven ", "")),
        "Line status": (r) => h("td", {}, badge(LINE_STATUS[r.line_status]?.label || r.line_status, LINE_STATUS[r.line_status]?.kind || "neutral")),
      };
      // One value per order, shown once beside all of its lines.
      const perOrder = {
        "Order": (r) => h("td", { class: "order-cell" }, `Order ${r.order_no}`),
        "Ordered": (r) => h("td", {}, fmt.dateTime(r.reserved_at)),
        "Order ready": (r) => h("td", {}, r.order_ready ? badge("Yes", "success") : badge("No", "warning")),
        "Overdue": (r) => h("td", {}, r.overdue ? badge("Overdue", "danger") : badge("On time", "neutral", { dot: false })),
      };
      const spare = () => Array.from({ length: COLUMN_WIDTHS.length - columns.length }, () => h("td", { class: "spare" }));
      const tbody = h("tbody");
      for (const [, rows] of orders) {
        rows.forEach((r, n) => tbody.append(h("tr", { class: n === 0 ? "order-first" : "" },
          columns.map((c) => {
            if (!perOrder[c]) return cell[c](r);
            if (n > 0) return null;
            const td = perOrder[c](r);
            td.setAttribute("rowspan", String(rows.length));
            return td;
          }),
          spare())));
      }
      return card({
        id, title, subtitle: subtitle(orders.length, lines.length),
        body: lines.length ? h("div", { class: "table-wrap" }, h("table", { class: "orders-table" },
          h("caption", { class: "sr-only" }, `${title}: open click-and-collect order lines`),
          h("colgroup", {}, COLUMN_WIDTHS.map((w) => h("col", { style: `width:${w}` }))),
          h("thead", {}, h("tr", {}, columns.map((c) => h("th", { scope: "col" }, c)),
            spare().map(() => h("th", { "aria-hidden": "true" })))),
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
      const tile = (label, value, note, tone, patch) => h("button", { class: `kpi ${tone}`, type: "button", onclick: () => app.setParams(patch) },
        h("span", { class: "kpi-label" }, label), h("strong", { class: "kpi-value" }, fmt.num(value)), h("span", { class: "kpi-note" }, note));
      return h("div", { class: "kpis kpis-4" },
        tile("Overdue", overdue, "ready orders not collected within 3 days", overdue ? "bad" : "good", { overdue: "1", rstatus: "" }),
        tile("To send", toSend, "item lines to send to another store", toSend ? "warn" : "good", { rstatus: "waiting to be sent", overdue: "" }),
        tile("In transit", inTransit, "item lines on the way to the pickup store", "neutral", { rstatus: "in transit", overdue: "" }),
        tile("Ready to collect", ready, "whole orders waiting for the customer", "good", { rstatus: "ready for collection", overdue: "" }));
    }

    load().catch(() => {});
    return {
      update(next) { params = next; render(); },
      reload: () => load(),
    };
  },
};
