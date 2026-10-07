// Store stock (Report 1: current stock by store) + sales history.

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, segmented, table, pager, tabs, errorState, keepFocus } from "../components/ui.js";

function stockStatus(n) {
  if (n === 0) return { label: "Out of stock", kind: "danger" };
  if (n <= 2) return { label: "Low stock", kind: "warning" };
  return { label: "Available", kind: "success" };
}

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    let stock = null, stockErr = null;
    let events = null, eventsKey = null, eventsErr = null;
    let sales = null, salesErr = null;
    let token = 0, evToken = 0;

    async function loadStock() {
      const my = ++token;
      stockErr = null;
      try {
        const r = await get("/stock");
        if (my !== token) return;
        stock = r;
        app.markRead(r.meta);
      } catch (err) {
        if (my !== token) return;
        stockErr = err;
        render();
        throw err;
      }
      render();
    }

    function eventQuery() {
      if (!params.product || !params.store_sel) return null;
      return { product: params.product, store: params.store_sel, from: params.hfrom, to: params.hto, offset: params.hoff, limit: 25 };
    }

    async function loadEvents(force = false) {
      const q = eventQuery();
      const key = JSON.stringify(q);
      if (!q) { events = null; eventsKey = null; return; }
      if (!force && key === eventsKey) return;
      const my = ++evToken;
      eventsKey = key; events = null; eventsErr = null;
      render();
      try {
        const r = await get("/stock/events", q);
        if (my !== evToken) return;
        events = r;
      } catch (err) {
        if (my !== evToken) return;
        eventsErr = err;
      }
      render();
    }

    async function loadSales() {
      salesErr = null;
      try { sales = await get("/sales"); app.markRead(sales.meta); } catch (err) { salesErr = err; }
      render();
    }

    function render() { keepFocus(root, draw); }

    function draw() {
      clear(root);
      root.append(h("div", { class: "page-head" },
        h("div", {},
          h("h1", {}, "Store stock"),
          h("p", { class: "subtitle" }, "What each store has on the shelf, and what is held for online orders."))));
      root.append(tabs([{ value: "stock", label: "Current stock" }, { value: "sales", label: "Sales" }],
        params.view === "sales" ? "sales" : "stock", (v) => app.setParams({ view: v === "stock" ? "" : v }), "Inventory views"));
      if (params.view === "sales") return drawSales();
      if (stockErr) return root.append(card({ label: "Error", body: errorState(stockErr, () => loadStock().catch(() => {})) }));
      if (!stock) return root.append(card({ label: "Loading", body: loading("Loading store stock") }));
      drawStock();
    }

    // ---------- current stock ----------
    function filteredRows() {
      const q = (params.q || "").toLowerCase();
      return stock.data.rows.filter((r) =>
        (!params.store || r.store_code === params.store) &&
        (!params.cat || r.category === params.cat) &&
        (!q || r.product_name.toLowerCase().includes(q) || r.product_code.toLowerCase().includes(q)) &&
        (!params.low || r.low_stock));
    }

    function drawStock() {
      const all = stock.data.rows;
      const stores = [...new Map(all.map((r) => [r.store_code, r.store_name])).entries()];
      const products = [...new Map(all.map((r) => [r.product_code, r.product_name])).entries()];
      const cats = [...new Set(all.map((r) => r.category))].sort();
      const rows = filteredRows();
      const search = h("input", { type: "search", "data-fk": "q", value: params.q || "", placeholder: "Name or code" });
      let t;
      search.addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => app.setParams({ q: search.value.trim() }), 200); });
      const any = params.store || params.cat || params.q || params.low;
      root.append(h("div", { class: "filters", role: "search", "aria-label": "Filter stock" },
        field("Store", select([{ value: "", label: "All stores" }, ...stores.map(([c, n]) => ({ value: c, label: `${c} · ${n.replace("PetHaven ", "")}` }))],
          params.store || "", (v) => app.setParams({ store: v }), { "data-fk": "store" })),
        field("Category", select([{ value: "", label: "All categories" }, ...cats.map((c) => ({ value: c, label: c }))],
          params.cat || "", (v) => app.setParams({ cat: v }), { "data-fk": "cat" })),
        field("Product", search, { wide: true }),
        h("label", { class: "check" }, h("input", { type: "checkbox", "data-fk": "low", checked: !!params.low,
          onchange: (e) => app.setParams({ low: e.target.checked ? "1" : "" }) }), "Low stock only"),
        segmented("View", [{ value: "matrix", label: "By store" }, { value: "table", label: "List" }],
          params.layout === "table" ? "table" : "matrix", (v) => app.setParams({ layout: v === "matrix" ? "" : v })),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ store: "", cat: "", q: "", low: "" }) }, "Clear filters") : null));

      if (params.product) root.append(productPanel(products));
      if (params.product && params.store_sel) root.append(historyCard());

      if (params.layout !== "table") root.append(matrixCard(rows));
      else root.append(card({
        id: "stock-table", title: "Stock by store and product",
        subtitle: `${rows.length} of ${all.length} store shelves.`,
        body: table({
          caption: "Available, reserved and on-hand units per store and product",
          columns: [
            { label: "Store", render: (r) => r.store_name.replace("PetHaven ", ""), sub: (r) => r.store_code },
            { label: "Product", render: (r) => r.product_name, sub: (r) => r.product_code },
            { label: "Category", key: "category" },
            { label: "Available", num: true, render: (r) => fmt.num(r.available) },
            { label: "Reserved", num: true, render: (r) => fmt.num(r.reserved) },
            { label: "On hand", num: true, render: (r) => fmt.num(r.on_hand) },
            { label: "Stock status", render: (r) => { const s = stockStatus(r.available); return badge(s.label, s.kind); } },
          ],
          rows, rowKey: (r) => `${r.store_code}-${r.product_code}`,
          selectedKey: params.product && params.store_sel ? `${params.store_sel}-${params.product}` : undefined,
          onSelect: (r) => app.setParams({ product: r.product_code, store_sel: r.store_code, hoff: "", hfrom: "", hto: "" }),
          empty: state("", "No balances match these filters", "", h("button", { class: "btn", type: "button", onclick: () => app.setParams({ store: "", cat: "", q: "", low: "" }) }, "Clear filters")),
        }),
        foot: "Available = on the shelf, free to sell. Reserved = held for click & collect orders. Low stock = 2 or fewer available.",
      }));
    }

    function productPanel(products) {
      const name = new Map(products).get(params.product);
      const rows = stock.data.rows.filter((r) => r.product_code === params.product);
      return card({
        id: "product-by-store", title: name ? `${name} by store` : `Product ${params.product}`,
        subtitle: `${params.product} · select a store to see its event history.`,
        actions: h("button", { class: "btn btn-small", type: "button", onclick: () => app.setParams({ product: "", store_sel: "", hoff: "", hfrom: "", hto: "" }) }, "Close"),
        body: rows.length ? table({
          caption: "Available and reserved units of the selected product at each store",
          columns: [
            { label: "Store", render: (r) => r.store_name.replace("PetHaven ", ""), sub: (r) => r.store_code },
            { label: "Available", num: true, render: (r) => fmt.num(r.available) },
            { label: "Reserved", num: true, render: (r) => fmt.num(r.reserved) },
            { label: "On hand", num: true, render: (r) => fmt.num(r.on_hand) },
            { label: "Stock status", render: (r) => { const s = stockStatus(r.available); return badge(s.label, s.kind); } },
            { label: "Last event", render: (r) => fmt.dateTime(r.last_event_at) },
          ],
          rows, rowKey: (r) => r.store_code, selectedKey: params.store_sel,
          onSelect: (r) => app.setParams({ store_sel: r.store_code, hoff: "", hfrom: "", hto: "" }),
        }) : state("", "This product is not in the warehouse", "It may not be on the warehouse product list yet."),
      });
    }

    function historyCard() {
      const from = h("input", { type: "date", "data-fk": "hfrom", value: params.hfrom || "", onchange: (e) => app.setParams({ hfrom: e.target.value, hoff: "" }) });
      const to = h("input", { type: "date", "data-fk": "hto", value: params.hto || "", onchange: (e) => app.setParams({ hto: e.target.value, hoff: "" }) });
      let body;
      if (eventsErr) body = errorState(eventsErr, () => loadEvents(true));
      else if (!events) body = loading("Loading events");
      else body = h("div", {}, table({
        caption: "Warehouse stock events for the selected store and product, newest first",
        columns: [
          { label: "Event time", render: (r) => fmt.dateTime(r.event_ts), sub: (r) => `Event ${r.event_id}` },
          { label: "Event type", render: (r) => r.event_label, sub: (r) => (r.event_type === "checkout_blocked" ? "Outcome only: no stock moved" : r.event_type) },
          { label: "Available change", num: true, render: (r) => fmt.signed(r.available_change) },
          { label: "Reserved change", num: true, render: (r) => fmt.signed(r.reserved_change) },
          { label: "Units involved", num: true, render: (r) => fmt.num(r.units) },
          { label: "Order / basket", render: (r) => (r.order_ref ? (/^\d+$/.test(r.order_ref) ? `Order ${r.order_ref}` : r.order_ref) : "—"),
            sub: (r) => (r.pickup_store_code && r.pickup_store_code !== r.store_code ? `Pickup store ${r.pickup_store_code}` : (r.pickup_store_code ? "Pickup here" : "")) },
          { label: "", render: (r) => h("a", { href: `#/integration?trace_event=${encodeURIComponent(r.event_id)}` }, "Details") },
        ],
        rows: events.data.rows,
        empty: state("", "No events for this store and product", params.hfrom || params.hto ? "Try a wider date range." : ""),
      }), pager(events.data, (off) => app.setParams({ hoff: off ? String(off) : "" })));
      return card({
        id: "event-history", title: `Event history · ${params.product} at ${params.store_sel}`,
        subtitle: "Every sale, delivery and order that changed this store's stock.",
        actions: [field("From", from), field("To", to),
          params.hfrom || params.hto ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ hfrom: "", hto: "", hoff: "" }) }, "Clear dates") : null],
        body,
      });
    }

    function matrixCard(rows) {
      const measure = params.measure === "reserved" ? "reserved" : "available";
      const stores = [...new Map(rows.map((r) => [r.store_code, r.store_name])).entries()];
      const byProduct = new Map();
      for (const r of rows) {
        if (!byProduct.has(r.product_code)) byProduct.set(r.product_code, { code: r.product_code, name: r.product_name, cells: {} });
        byProduct.get(r.product_code).cells[r.store_code] = r;
      }
      const tbody = h("tbody");
      for (const p of byProduct.values()) {
        const tr = h("tr", { class: `clickable${params.product === p.code ? " selected" : ""}`, tabindex: "0", "data-fk": `mrow-${p.code}` },
          h("th", { scope: "row", style: "background:none;font-weight:500;color:var(--text)" }, p.name, h("span", { class: "cell-sub" }, p.code)),
          stores.map(([sc]) => {
            const c = p.cells[sc];
            if (!c) return h("td", { class: "num" }, "—");
            const v = c[measure];
            const cls = measure === "available" ? (v === 0 ? "cell-zero" : v <= 2 ? "cell-low" : "") : "";
            const label = measure === "available" ? stockStatus(v).label : "Reserved";
            return h("td", { class: `num ${cls}`, title: `${c.store_name}: ${v} ${measure} (${label})` }, fmt.num(v));
          }));
        const pick = () => app.setParams({ product: p.code, store_sel: "" });
        tr.addEventListener("click", pick);
        tr.addEventListener("keydown", (e) => { if (e.key === "Enter") pick(); });
        tbody.append(tr);
      }
      return card({
        id: "stock-matrix", title: "Stock by store",
        subtitle: "Select a product to see its detail and history.",
        actions: field("Measure", select([{ value: "available", label: "Available" }, { value: "reserved", label: "Reserved" }], measure,
          (v) => app.setParams({ measure: v === "available" ? "" : v }), { "data-fk": "measure" })),
        body: rows.length ? h("div", { class: "table-wrap" }, h("table", { class: "matrix" },
          h("caption", { class: "sr-only" }, `${measure} units per product and store`),
          h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "Product"), stores.map(([sc, n]) => h("th", { scope: "col", class: "num" }, n.replace("PetHaven ", ""), h("span", { class: "cell-sub" }, sc))))),
          tbody)) : state("", "No balances match these filters", ""),
        foot: measure === "available" ? "Red = out of stock. Amber = low (1–2 left)." : "Units held for click & collect orders at each store.",
      });
    }

    // ---------- sales history (secondary) ----------
    function drawSales() {
      if (salesErr) return root.append(card({ label: "Error", body: errorState(salesErr, loadSales) }));
      if (!sales) { root.append(card({ label: "Loading", body: loading("Loading sales") })); return; }
      const all = sales.data.rows;
      const stores = [...new Set(all.map((r) => r.store_name))].sort();
      const cats = [...new Set(all.map((r) => r.category))].sort();
      const rows = all.filter((r) =>
        (!params.sfrom || r.full_date >= params.sfrom) && (!params.sto || r.full_date <= params.sto) &&
        (!params.sstore || r.store_name === params.sstore) && (!params.schan || r.channel === params.schan) &&
        (!params.scat || r.category === params.scat));
      const days = new Map();
      for (const r of rows) {
        const d = days.get(r.full_date) || { date: r.full_date, day: r.day_name, "in-store": 0, online: 0 };
        d[r.channel] += r.units_sold;
        days.set(r.full_date, d);
      }
      const dayRows = [...days.values()].sort((a, b) => a.date.localeCompare(b.date));
      const max = Math.max(1, ...dayRows.flatMap((d) => [d["in-store"], d.online]));
      const any = params.sfrom || params.sto || params.sstore || params.schan || params.scat;
      root.append(h("div", { class: "filters" },
        field("From", h("input", { type: "date", "data-fk": "sfrom", value: params.sfrom || "", onchange: (e) => app.setParams({ sfrom: e.target.value }) })),
        field("To", h("input", { type: "date", "data-fk": "sto", value: params.sto || "", onchange: (e) => app.setParams({ sto: e.target.value }) })),
        field("Store", select([{ value: "", label: "All stores" }, ...stores.map((s) => ({ value: s, label: s.replace("PetHaven ", "") }))], params.sstore || "", (v) => app.setParams({ sstore: v }), { "data-fk": "sstore" })),
        field("Channel", select([{ value: "", label: "Both channels" }, { value: "in-store", label: "In-store" }, { value: "online", label: "Online" }], params.schan || "", (v) => app.setParams({ schan: v }), { "data-fk": "schan" })),
        field("Category", select([{ value: "", label: "All categories" }, ...cats.map((c) => ({ value: c, label: c }))], params.scat || "", (v) => app.setParams({ scat: v }), { "data-fk": "scat" })),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ sfrom: "", sto: "", sstore: "", schan: "", scat: "" }) }, "Clear filters") : null));
      root.append(h("div", { class: "stack" },
        card({
          id: "sales-days", title: "Units sold per day", subtitle: "In-store till sales and online orders (credited to the pickup store).",
          actions: h("div", { class: "legend" },
            h("span", {}, h("i", { class: "swatch", style: "background:var(--chart-warehouse)" }), "In-store"),
            h("span", {}, h("i", { class: "swatch", style: "background:var(--chart-website)" }), "Online")),
          body: dayRows.length ? h("div", { class: "card-body" }, h("div", { class: "bars" }, dayRows.map((d) =>
            h("div", { class: "bar-row", style: "cursor:default" },
              h("span", { class: "bar-label" }, fmt.date(d.date), h("small", {}, d.day)),
              h("span", { class: "bar-pair" },
                h("span", { class: "bar-line" }, h("span", { class: "bar wh", style: `width:${Math.max(0, d["in-store"] / max * 100)}%` }), h("span", { class: "bar-val" }, `${fmt.num(d["in-store"])} in-store`)),
                h("span", { class: "bar-line" }, h("span", { class: "bar web", style: `width:${Math.max(0, d.online / max * 100)}%` }), h("span", { class: "bar-val" }, `${fmt.signed(d.online)} online`))))))) : state("", "No sales match these filters", ""),
        }),
        card({
          id: "sales-table", title: "Daily sales detail", subtitle: `${rows.length} rows · units sold per day, store, channel and category`,
          body: table({
            caption: "Units sold per day, store, channel and category",
            columns: [
              { label: "Date", render: (r) => fmt.date(r.full_date), sub: (r) => r.day_name },
              { label: "Store", render: (r) => r.store_name.replace("PetHaven ", "") },
              { label: "Channel", render: (r) => (r.channel === "online" ? "Online" : "In-store") },
              { label: "Category", key: "category" },
              { label: "Units sold", num: true, render: (r) => fmt.signed(r.units_sold).replace(/^\+/, "") },
              { label: "Sales value at current price", num: true, render: (r) => `$${Number(r.sales_value_at_current_price).toFixed(2)}` },
            ],
            rows, empty: state("", "No sales match these filters", ""),
          }),
          foot: "Value = units × today's shelf price. Online can be negative on a day with more cancellations than orders.",
        })));
    }

    loadStock().catch(() => {});
    loadEvents();
    if (params.view === "sales") loadSales();
    return {
      update(next) {
        params = next;
        if (params.view === "sales" && !sales && !salesErr) loadSales();
        render();
        loadEvents();
      },
      reload: async () => {
        await Promise.all([loadStock(), params.view === "sales" ? loadSales() : null]);
        await loadEvents(true);
      },
    };
  },
};
