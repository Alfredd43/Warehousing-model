// Orders & lost sales (Report 3: items blocked at checkout) + open click & collect orders.

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, table, tabs, kv, errorState, keepFocus } from "../components/ui.js";

const sydneyDate = new Intl.DateTimeFormat("en-CA", { timeZone: "Australia/Sydney", year: "numeric", month: "2-digit", day: "2-digit" });
const dayOf = (iso) => sydneyDate.format(new Date(iso));

const REASON = { stale: "Website number was out of date", split: "No single store had enough" };

const LINE_STATUS = {
  "waiting to be sent": { label: "Waiting to be sent", kind: "warning" },
  "in transit": { label: "In transit", kind: "info" },
  "ready for collection": { label: "Ready for collection", kind: "success" },
};

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    let blocked = null, blockedErr = null;
    let res = null, resErr = null;
    let attempt = null, attemptErr = null, attemptKey = null;
    let token = 0, atToken = 0;
    const collapsed = new Set();

    async function loadLists() {
      const my = ++token;
      blockedErr = resErr = null;
      const [b, r] = await Promise.allSettled([get("/checkout/blocked"), get("/reservations")]);
      if (my !== token) return;
      if (b.status === "fulfilled") { blocked = b.value; app.markRead(b.value.meta); } else blockedErr = b.reason;
      if (r.status === "fulfilled") res = r.value; else resErr = r.reason;
      render();
      if (blockedErr || resErr) throw blockedErr || resErr;
    }

    async function loadAttempt(force = false) {
      const id = params.attempt;
      if (!id) { attempt = null; attemptKey = null; return; }
      if (!force && id === attemptKey) return;
      const my = ++atToken;
      attemptKey = id; attempt = null; attemptErr = null;
      render();
      try {
        const r = await get(`/checkout/attempts/${encodeURIComponent(id)}`);
        if (my !== atToken) return;
        attempt = r;
      } catch (err) {
        if (my !== atToken) return;
        attemptErr = err;
      }
      render();
    }

    function render() { keepFocus(root, draw); }

    function draw() {
      clear(root);
      const tab = params.tab === "reservations" ? "reservations" : "blocked";
      root.append(h("div", { class: "page-head" },
        h("div", {},
          h("h1", {}, "Orders & lost sales"),
          h("p", { class: "subtitle" }, tab === "blocked"
            ? "Items customers tried to buy online that no store could supply. Nobody was charged."
            : "Click & collect orders still waiting to be collected."))));
      root.append(tabs([{ value: "blocked", label: "Lost sales" }, { value: "reservations", label: "Click & collect orders" }], tab,
        (v) => app.setParams({ tab: v === "blocked" ? "" : v }), "Checkout views"));
      if (tab === "blocked") drawBlocked(); else drawReservations();
    }

    // ---------- blocked items ----------
    function drawBlocked() {
      if (blockedErr) return root.append(card({ label: "Error", body: errorState(blockedErr, () => loadLists().catch(() => {})) }));
      if (!blocked) return root.append(card({ label: "Loading", body: loading() }));
      const all = blocked.data.rows;
      const products = [...new Map(all.map((r) => [r.product_code, r.product_name])).entries()].sort();
      const stores = [...new Map(all.map((r) => [r.pickup_store_code, r.pickup_store])).entries()].sort();
      const rows = all.filter((r) =>
        (!params.from || dayOf(r.attempted_at) >= params.from) && (!params.to || dayOf(r.attempted_at) <= params.to) &&
        (!params.product || r.product_code === params.product) && (!params.pickup || r.pickup_store_code === params.pickup) &&
        (!params.reason || r.reason_code === params.reason));
      const any = params.from || params.to || params.product || params.pickup || params.reason;
      root.append(h("div", { class: "filters", role: "search", "aria-label": "Filter blocked items" },
        field("From", h("input", { type: "date", "data-fk": "from", value: params.from || "", onchange: (e) => app.setParams({ from: e.target.value }) })),
        field("To", h("input", { type: "date", "data-fk": "to", value: params.to || "", onchange: (e) => app.setParams({ to: e.target.value }) })),
        field("Product", select([{ value: "", label: "All products" }, ...products.map(([c, n]) => ({ value: c, label: `${c} · ${n}` }))], params.product || "", (v) => app.setParams({ product: v }), { "data-fk": "product" }), { wide: true }),
        field("Pickup store", select([{ value: "", label: "All pickup stores" }, ...stores.map(([c, n]) => ({ value: c, label: n.replace("PetHaven ", "") }))], params.pickup || "", (v) => app.setParams({ pickup: v }), { "data-fk": "pickup" })),
        field("Why", select([{ value: "", label: "Any reason" }, { value: "stale", label: REASON.stale }, { value: "split", label: REASON.split }], params.reason || "", (v) => app.setParams({ reason: v }), { "data-fk": "reason" }), { wide: true }),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ from: "", to: "", product: "", pickup: "", reason: "" }) }, "Clear filters") : null));

      const selectedEvent = params.event;
      const units = rows.reduce((n, r) => n + (r.requested || 0), 0);
      root.append(h("p", { class: "lede" }, h("b", {}, `${rows.length} lost sale${rows.length === 1 ? "" : "s"}`),
        ` · ${fmt.units(units)}`, rows.length !== all.length ? ` (of ${all.length} recorded)` : ""));
      if (params.attempt) root.append(attemptCard());
      root.append(card({
        id: "blocked-table", title: "Lost sales",
        subtitle: "Select a row to see the customer's checkout.",
        body: table({
          caption: "Items blocked at checkout before payment",
          columns: [
            { label: "When", render: (r) => fmt.dateTime(r.attempted_at) },
            { label: "Product", render: (r) => r.product_name, sub: (r) => r.product_code },
            { label: "Wanted", num: true, render: (r) => fmt.num(r.requested) },
            { label: "Website showed", num: true, render: (r) => fmt.num(r.website_shown_then) },
            { label: "Stores had", num: true, render: (r) => fmt.num(r.combined_available_then) },
            { label: "Pickup store", render: (r) => r.pickup_store.replace("PetHaven ", "") },
            { label: "Why", render: (r) => badge(REASON[r.reason_code], r.reason_code === "stale" ? "warning" : "info") },
          ],
          rows, rowKey: (r) => r.event_id, selectedKey: selectedEvent,
          onSelect: (r) => app.setParams({ attempt: r.attempt_no, event: r.event_id }),
          empty: state("", "No blocked item records match these filters", "",
            any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ from: "", to: "", product: "", pickup: "", reason: "" }) }, "Clear filters") : null),
        }),
        foot: "Website number was out of date: the stores together had fewer than the customer wanted. No single store had enough: there was enough in total, but each item must come from one store.",
      }));
    }

    function attemptCard() {
      const close = h("button", { class: "btn btn-small", type: "button", onclick: () => app.setParams({ attempt: "", event: "" }) }, "Close");
      if (attemptErr) return card({ id: "attempt", title: "Source checkout record", actions: close, body: errorState(attemptErr, () => loadAttempt(true)) });
      if (!attempt) return card({ id: "attempt", title: "Source checkout record", actions: close, body: loading() });
      const a = attempt.data.attempt;
      const items = attempt.data.items;
      const differ = items.some((i) => i.website_values_differ);
      return card({
        id: "attempt", title: `Customer checkout (attempt ${a.attempt_no})`,
        subtitle: "As recorded by the online store.",
        actions: close,
        body: h("div", {},
          h("div", { class: "card-body" },
            differ ? h("div", { class: "banner warn" }, "The website number captured at checkout differs from the report's reconstruction for at least one item. Investigate before relying on either value.") : null,
            kv([
              ["Basket", `Bag ${a.basket_id} (${a.basket_status === "open" ? "still open" : "checked out"})`],
              ["Outcome", a.outcome === "blocked" ? badge("Blocked before payment", "warning") : a.outcome === "paid" ? badge("Paid", "success") : a.outcome],
              ["Attempted at", fmt.dateTimeSec(a.attempted_at)],
              ["Pickup store", `${a.pickup_cp_name} (${a.pickup_cp_code}${a.pickup_store_code ? ` → ${a.pickup_store_code}` : ""})`],
              ["Order", a.order_no ? `Order ${a.order_no}` : "No successful order created for this attempt"],
            ])),
          table({
            caption: "Items in this checkout attempt",
            columns: [
              { label: "Item", render: (i) => i.title, sub: (i) => i.item_no },
              { label: "Requested", num: true, render: (i) => fmt.num(i.quantity) },
              { label: "Website snapshot (source)", num: true, render: (i) => fmt.num(i.website_qty_shown) },
              { label: "Report reconstruction", num: true, render: (i) => (i.report_website_shown === null ? "—" : fmt.num(i.report_website_shown)),
                sub: (i) => (i.report_combined_available === null ? "" : `combined available ${fmt.num(i.report_combined_available)}`) },
              { label: "Result", render: (i) => (i.result === "available" ? badge("Available", "success") : badge("Unavailable", "warning")) },
              { label: "Supplying collection point", render: (i) => (i.source_cp_name ? i.source_cp_name.replace("Click & Collect - ", "") : "None") },
              { label: "Data trace", render: (i) => (i.event_id ? h("a", { href: `#/integration?trace_event=${i.event_id}` }, "View data trace")
                : i.stg_id ? h("a", { href: `#/integration?trace_table=stg_checkout_item&trace_id=${i.stg_id}` }, "View staging") : "—") },
            ],
            rows: items,
          }),
          attempt.data.basket_attempts.length > 1 ? h("div", { class: "table-note" },
            `All attempts for bag ${a.basket_id}: `,
            attempt.data.basket_attempts.map((x, n) => [n ? ", " : "",
              x.attempt_no === a.attempt_no ? h("b", {}, `#${x.attempt_no} ${x.outcome}`) : h("button", { class: "btn-link", type: "button", onclick: () => app.setParams({ attempt: x.attempt_no, event: "" }) }, `#${x.attempt_no} ${x.outcome}`)])) : null,
          null),
      });
    }

    // ---------- open reservations ----------
    function drawReservations() {
      if (resErr) return root.append(card({ label: "Error", body: errorState(resErr, () => loadLists().catch(() => {})) }));
      if (!res) return root.append(card({ label: "Loading", body: loading() }));
      const all = res.data.rows;
      const stores = [...new Map(all.flatMap((r) => [[r.pickup_store_code, r.pickup_store], [r.source_store_code, r.taken_from]])).entries()].sort();
      const storeOpts = (lbl) => [{ value: "", label: lbl }, ...stores.map(([c, n]) => ({ value: c, label: n.replace("PetHaven ", "") }))];
      const rows = all.filter((r) =>
        (!params.rpickup || r.pickup_store_code === params.rpickup) && (!params.rsource || r.source_store_code === params.rsource) &&
        (!params.rstatus || r.line_status === params.rstatus) && (!params.overdue || r.overdue));
      const any = params.rpickup || params.rsource || params.rstatus || params.overdue;
      root.append(h("div", { class: "filters", role: "search", "aria-label": "Filter reservations" },
        field("Pickup store", select(storeOpts("All pickup stores"), params.rpickup || "", (v) => app.setParams({ rpickup: v }), { "data-fk": "rpickup" })),
        field("Source store", select(storeOpts("All source stores"), params.rsource || "", (v) => app.setParams({ rsource: v }), { "data-fk": "rsource" })),
        field("Line status", select([{ value: "", label: "All statuses" }, ...Object.entries(LINE_STATUS).map(([v, s]) => ({ value: v, label: s.label }))], params.rstatus || "", (v) => app.setParams({ rstatus: v }), { "data-fk": "rstatus" })),
        h("label", { class: "check" }, h("input", { type: "checkbox", "data-fk": "overdue", checked: !!params.overdue, onchange: (e) => app.setParams({ overdue: e.target.checked ? "1" : "" }) }), "Overdue only"),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ rpickup: "", rsource: "", rstatus: "", overdue: "" }) }, "Clear filters") : null));

      if (!all.length) { root.append(card({ id: "reservations", title: "Click & collect orders", body: state("", "No open orders", "Every click & collect order has been collected or cancelled.") })); return; }
      const orders = new Map();
      for (const r of rows) {
        if (!orders.has(r.order_no)) orders.set(r.order_no, []);
        orders.get(r.order_no).push(r);
      }
      const tbody = h("tbody");
      for (const [order, lines] of orders) {
        const first = lines[0];
        const hidden = collapsed.has(order);
        const toggle = h("button", { class: "btn-link", type: "button", "aria-expanded": String(!hidden), "data-fk": `order-${order}`,
          onclick: () => { hidden ? collapsed.delete(order) : collapsed.add(order); render(); } }, `Order ${order}`);
        tbody.append(h("tr", { class: "group-row" },
          h("td", {}, toggle),
          h("td", { colspan: "3" }, `Pickup at ${first.pickup_store.replace("PetHaven ", "")} · ${lines.length} open line${lines.length === 1 ? "" : "s"} shown`),
          h("td", { colspan: "2" }, "Whole order: ", first.order_ready ? badge("Ready to collect", "success") : badge("Not ready", "warning")),
          h("td", { colspan: "3" }, lines.some((l) => l.overdue) ? badge("Overdue", "danger") : "")));
        if (hidden) continue;
        for (const r of lines) {
          tbody.append(h("tr", {},
            h("td", { class: "muted" }, ""),
            h("td", {}, r.product_name, h("span", { class: "cell-sub" }, r.product_code)),
            h("td", { class: "num" }, fmt.num(r.units)),
            h("td", {}, r.taken_from.replace("PetHaven ", ""), h("span", { class: "cell-sub" }, r.is_transfer ? "Transfer to pickup store" : "Same store")),
            h("td", {}, r.pickup_store.replace("PetHaven ", "")),
            h("td", {}, badge(LINE_STATUS[r.line_status]?.label || r.line_status, LINE_STATUS[r.line_status]?.kind || "neutral")),
            h("td", {}, r.order_ready ? "Yes" : "No"),
            h("td", { class: "num" }, r.waiting_for?.display ?? "—", h("span", { class: "cell-sub" }, `since ${fmt.dateTime(r.reserved_at)}`)),
            h("td", {}, r.overdue ? badge("Overdue", "danger") : badge("On time", "neutral", { dot: false }))));
        }
      }
      root.append(card({
        id: "reservations", title: "Click & collect orders",
        subtitle: `${orders.size} open order${orders.size === 1 ? "" : "s"} (${rows.length} item line${rows.length === 1 ? "" : "s"}).`,
        body: rows.length ? h("div", { class: "table-wrap" }, h("table", {},
          h("caption", { class: "sr-only" }, "Open click-and-collect order lines grouped by order"),
          h("thead", {}, h("tr", {}, ["Order", "Product", "Units", "Source store", "Pickup store", "Line status", "Order ready", "Waiting time", "Overdue"]
            .map((c) => h("th", { scope: "col", class: c === "Units" || c === "Waiting time" ? "num" : "" }, c)))),
          tbody)) : state("", "No open lines match these filters", ""),
        foot: "Overdue = not collected within 3 days. Items from another store go: waiting to be sent → in transit → ready for collection.",
      }));
    }

    loadLists().catch(() => {});
    loadAttempt();
    return {
      update(next) { params = next; render(); loadAttempt(); },
      reload: async () => { await loadLists(); await loadAttempt(true); },
    };
  },
};
