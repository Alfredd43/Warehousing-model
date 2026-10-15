// Store stock (Report 1: current stock by store) with units sold in the last 7 days.

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, segmented, errorState, keepFocus } from "../components/ui.js";

function stockStatus(n) {
  if (n === 0) return { label: "Out of stock", kind: "danger" };
  if (n <= 2) return { label: "Low stock", kind: "warning" };
  return { label: "Available", kind: "success" };
}

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    let stock = null, stockErr = null;
    let events = null, eventsKey = null, eventsErr = null, eventsMore = false;
    let drawerOpen = false;
    let expanded = false;
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

    // Stock movements of one product at one store, newest first, 20 at a time.
    const PAGE = 20;
    async function loadEvents({ force = false, more = false } = {}) {
      const key = params.product && params.store_sel ? `${params.product}@${params.store_sel}` : null;
      if (!key) { events = null; eventsKey = null; return; }
      if (!force && !more && key === eventsKey) return;
      const my = ++evToken;
      const offset = more ? events.rows.length : 0;
      if (!more) { eventsKey = key; events = null; }
      eventsErr = null; eventsMore = more;
      render();
      try {
        const r = await get("/stock/events", { product: params.product, store: params.store_sel, limit: PAGE, offset });
        if (my !== evToken) return;
        events = { rows: [...(more ? events.rows : []), ...r.data.rows], total: r.data.total };
      } catch (err) {
        if (my !== evToken) return;
        eventsErr = err;
      }
      eventsMore = false;
      render();
    }

    function closeDrawer() {
      const row = `srow-${params.product}-${params.store_sel}`;
      app.setParams({ product: "", store_sel: "" });
      root.querySelector(`[data-fk="${row}"]`)?.focus();
    }
    const onKey = (e) => {
      if (!root.isConnected) { document.removeEventListener("keydown", onKey); return; }
      if (e.key === "Escape" && params.product && params.store_sel) closeDrawer();
    };
    document.addEventListener("keydown", onKey);

    function render() { keepFocus(root, draw); }

    function draw() {
      clear(root);
      root.append(h("div", { class: "page-head" },
        h("div", {}, h("h1", {}, "Store stock"))));
      if (stockErr) return root.append(card({ label: "Error", body: errorState(stockErr, () => loadStock().catch(() => {})) }));
      if (!stock) return root.append(card({ label: "Loading", body: loading("Loading store stock") }));
      drawStock();
    }

    // ---------- current stock ----------
    // The chart ignores the search (it picks the product), the tables use every filter.
    function filteredRows({ search = true } = {}) {
      const q = search ? (params.q || "").toLowerCase() : "";
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
      const byProduct = params.layout === "product";
      root.append(h("div", { class: "filters", role: "search", "aria-label": "Filter stock" },
        field("Store", select([{ value: "", label: "All stores" }, ...stores.map(([c, n]) => ({ value: c, label: storeLabel(n) }))],
          params.store || "", (v) => app.setParams({ store: v }), { "data-fk": "store" })),
        field("Category", select([{ value: "", label: "All categories" }, ...cats.map((c) => ({ value: c, label: c }))],
          params.cat || "", (v) => app.setParams({ cat: v }), { "data-fk": "cat" })),
        field("Product", search, { wide: true }),
        h("label", { class: "check" }, h("input", { type: "checkbox", "data-fk": "low", checked: !!params.low,
          onchange: (e) => app.setParams({ low: e.target.checked ? "1" : "" }) }), "Low stock only"),
        // One store selected: a single table for it. All stores: group by store or by product.
        params.store ? null : segmented("View", [{ value: "store", label: "By store" }, { value: "product", label: "By product" }],
          byProduct ? "product" : "store", (v) => app.setParams({ layout: v === "store" ? "" : v })),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ store: "", cat: "", q: "", low: "" }) }, "Clear filters") : null));

      root.append(stockVsSoldCard(filteredRows({ search: false }), new Map(stores).get(params.store)));

      if (params.store) root.append(singleStoreCard(rows, new Map(stores).get(params.store)));
      else if (byProduct) root.append(byProductCard(rows));
      else root.append(byStoreCard(rows));

      const open = !!(params.product && params.store_sel);
      if (open) root.append(movesDrawer(new Map(products).get(params.product), new Map(stores).get(params.store_sel), !drawerOpen));
      drawerOpen = open;
    }

    // ---------- stock movements drawer ----------
    // One line per warehouse stock event, in plain words, with the source
    // document (supplier order or till receipt) underneath.
    function describe(r) {
      const order = r.order_ref;
      switch (r.event_type) {
        case "supplier_delivery": return r.supplier_name ? `Delivery from ${r.supplier_name}` : "Supplier delivery";
        case "store_sale": return "Sold in store";
        case "reservation": return `Held for online order ${order}`
          + (r.pickup_store_code && r.pickup_store_code !== r.store_code ? `, pickup at ${storeLabel(r.pickup_store_name)}` : "");
        case "transfer_out": return `Sent to ${storeLabel(r.pickup_store_name)} for online order ${order}`;
        case "transfer_in": return r.from_store_name
          ? `Received from ${storeLabel(r.from_store_name)} for online order ${order}` : `Received for online order ${order}`;
        case "collection": return `Collected by customer, order ${order}`;
        case "cancellation": return r.available_change > 0 ? `Order ${order} cancelled, back on shelf` : `Order ${order} cancelled`;
        case "checkout_blocked": return `Checkout blocked, ${fmt.units(r.units)} wanted`;
        default: return r.event_label;
      }
    }

    function change(r) {
      const parts = [];
      if (r.available_change) parts.push(`${fmt.signed(r.available_change)}${r.reserved_change ? " shelf" : ""}`);
      if (r.reserved_change) parts.push(`${fmt.signed(r.reserved_change)} held`);
      return parts.length ? parts.join(", ") : "nothing moved";
    }

    function movesDrawer(productName, storeName, entering) {
      const bal = stock.data.rows.find((r) => r.product_code === params.product && r.store_code === params.store_sel);
      let body;
      if (eventsErr && !events) body = errorState(eventsErr, () => loadEvents({ force: true }));
      else if (!events) body = loading("Loading stock movements");
      else if (!events.rows.length) body = state("", "No stock movements recorded", "");
      else body = h("div", {},
        h("ol", { class: "moves" }, events.rows.map((r) => h("li", { class: "move" },
          h("span", { class: "move-time" }, fmt.dateTime(r.event_ts)),
          h("span", { class: "move-what" }, describe(r), r.document ? h("span", { class: "cell-sub" }, r.document) : null),
          h("span", { class: `move-change${r.available_change < 0 ? " neg" : r.available_change > 0 ? " pos" : ""}` }, change(r))))),
        eventsErr ? errorState(eventsErr, () => loadEvents({ more: true })) : null,
        events.rows.length < events.total ? h("div", { class: "table-note" },
          h("button", { class: "btn-link", type: "button", "data-fk": "moves-more", disabled: eventsMore || undefined,
            onclick: () => loadEvents({ more: true }) }, eventsMore ? "Loading" : "Show more")) : null);
      return h("div", { class: "drawer-layer" },
        h("div", { class: "drawer-scrim", onclick: closeDrawer }),
        h("aside", { class: `drawer${entering ? " drawer-enter" : ""}`, role: "dialog", "aria-modal": "true", "aria-labelledby": "drawer-title" },
          h("div", { class: "drawer-head" },
            h("div", {},
              h("h2", { id: "drawer-title" }, productName || params.product),
              h("p", {}, [storeName ? storeLabel(storeName) : params.store_sel,
                bal ? ` · ${fmt.num(bal.available)} on shelf · ${fmt.num(bal.reserved)} held` : ""])),
            h("button", { class: "btn btn-small", type: "button", "data-fk": "drawer-close", "aria-label": "Close", onclick: closeDrawer }, "✕")),
          h("div", { class: "drawer-body" }, body)));
    }

    // ---------- stock tables ----------
    const storeLabel = (name) => name.replace("PetHaven ", "");
    const byCode = (a, b) => a.localeCompare(b);
    const lowNote = (rows) => { const n = rows.filter((r) => r.low_stock).length; return n ? `${n} low or out of stock` : ""; };
    const noMatch = () => state("", "No balances match these filters", "",
      h("button", { class: "btn", type: "button", onclick: () => app.setParams({ cat: "", q: "", low: "" }) }, "Clear filters"));

    // Available, reserved, on hand and status: the cells every stock table shares.
    function levelCells(r) {
      const s = stockStatus(r.available);
      const cls = r.available === 0 ? "cell-zero" : r.available <= 2 ? "cell-low" : "";
      return [
        h("td", { class: `num ${cls}`, title: `${r.available} available (${s.label})` }, fmt.num(r.available)),
        h("td", { class: "num" }, fmt.num(r.reserved)),
        h("td", { class: "num" }, fmt.num(r.on_hand)),
        h("td", {}, badge(s.label, s.kind)),
      ];
    }

    const rowHead = (label) => h("th", { scope: "row", style: "background:none;font-weight:500;color:var(--text)" }, label);

    function stockRow(r, cells) {
      const selected = params.product === r.product_code && params.store_sel === r.store_code;
      const tr = h("tr", { class: `clickable${selected ? " selected" : ""}`, tabindex: "0", "data-fk": `srow-${r.product_code}-${r.store_code}` }, cells);
      const pick = () => {
        app.setParams({ product: r.product_code, store_sel: r.store_code });
        root.querySelector('[data-fk="drawer-close"]')?.focus();
      };
      tr.addEventListener("click", pick);
      tr.addEventListener("keydown", (e) => { if (e.key === "Enter") pick(); });
      return tr;
    }

    const groupRow = (span, title, sub) => h("tr", { class: "group-row" },
      h("td", { colspan: String(span) }, title, sub ? h("span", { class: "cell-sub", style: "font-weight:400" }, sub) : null));

    function stockTable(caption, headers, tbody) {
      return h("div", { class: "table-wrap" }, h("table", { class: "matrix" },
        h("caption", { class: "sr-only" }, caption),
        h("thead", {}, h("tr", {}, headers.map(([label, num]) => h("th", { scope: "col", class: num ? "num" : undefined }, label)))),
        tbody));
    }

    function groupBy(rows, key) {
      const groups = new Map();
      for (const r of rows) {
        if (!groups.has(r[key])) groups.set(r[key], []);
        groups.get(r[key]).push(r);
      }
      return groups;
    }

    const PRODUCT_HEADERS = [["Product"], ["Category"], ["Available", true], ["Reserved", true], ["On hand", true], ["Stock status"]];
    const productCells = (r) => [rowHead(r.product_name), h("td", {}, r.category), ...levelCells(r)];

    // Store filter set: one table for that store, one row per product.
    function singleStoreCard(rows, name) {
      const sorted = [...rows].sort((a, b) => byCode(a.product_code, b.product_code));
      return card({
        id: "stock-store", title: name ? storeLabel(name) : params.store,
        subtitle: lowNote(sorted),
        body: sorted.length ? stockTable(`Available, reserved and on-hand units of each product at ${name || params.store}`,
          [...PRODUCT_HEADERS, ["Last event"]],
          h("tbody", {}, sorted.map((r) => stockRow(r, [...productCells(r), h("td", {}, fmt.dateTime(r.last_event_at))])))) : noMatch(),
      });
    }

    // All stores, "By store": one block per store, one row per product.
    function byStoreCard(rows) {
      const groups = groupBy([...rows].sort((a, b) => byCode(a.store_code, b.store_code) || byCode(a.product_code, b.product_code)), "store_code");
      const tbody = h("tbody");
      for (const [code, g] of groups) {
        tbody.append(groupRow(PRODUCT_HEADERS.length, storeLabel(g[0].store_name), lowNote(g)));
        for (const r of g) tbody.append(stockRow(r, productCells(r)));
      }
      return card({
        id: "stock-by-store", title: "Stock by store",
        body: rows.length ? stockTable("Available, reserved and on-hand units of each product, grouped by store", PRODUCT_HEADERS, tbody) : noMatch(),
      });
    }

    // All stores, "By product": one block per product, one row per store.
    function byProductCard(rows) {
      const headers = [["Store"], ["Available", true], ["Reserved", true], ["On hand", true], ["Stock status"]];
      const groups = groupBy([...rows].sort((a, b) => byCode(a.product_code, b.product_code) || byCode(a.store_code, b.store_code)), "product_code");
      const tbody = h("tbody");
      for (const [code, g] of groups) {
        const total = g.reduce((n, r) => n + r.available, 0);
        tbody.append(groupRow(headers.length, g[0].product_name,
          [g[0].category, `${fmt.num(total)} available`, lowNote(g)].filter(Boolean).join(" · ")));
        for (const r of g) tbody.append(stockRow(r, [rowHead(storeLabel(r.store_name)), ...levelCells(r)]));
      }
      return card({
        id: "stock-by-product", title: "Stock by product",
        body: rows.length ? stockTable("Available, reserved and on-hand units of each product at each store, grouped by product", headers, tbody) : noMatch(),
      });
    }

    // ---------- stock left vs units sold, least stock first ----------
    const SHOWN = 10;
    function stockVsSoldCard(rows, storeName) {
      const products = new Map();
      for (const r of rows) {
        const p = products.get(r.product_code) || { code: r.product_code, name: r.product_name, available: 0, reserved: 0, sold: 0 };
        p.available += r.available; p.reserved += r.reserved; p.sold += r.sold_7_days;
        products.set(r.product_code, p);
      }
      const list = [...products.values()].sort((a, b) => a.available - b.available || b.sold - a.sold || byCode(a.code, b.code));
      const shown = expanded ? list : list.slice(0, SHOWN);
      const max = Math.max(1, ...shown.map((p) => Math.max(p.available + p.reserved, p.sold)));
      const pct = (n) => `width:${(n / max) * 100}%`;
      const note = (p) => (p.available === 0 ? h("b", { class: "sv-zero" }, "out of stock") : p.available <= 2 ? h("b", { class: "sv-low" }, "low") : null);
      return card({
        id: "stock-vs-sold", title: storeName ? `${storeLabel(storeName)} · stock left and units sold` : "Stock left and units sold",
        actions: h("div", { class: "legend" },
          h("span", {}, h("i", { class: "swatch", style: "background:var(--chart-warehouse)" }), "Available"),
          h("span", {}, h("i", { class: "swatch", style: "background:var(--chart-reserved)" }), "Reserved"),
          h("span", {}, h("i", { class: "swatch", style: "background:var(--chart-website)" }), "Sold")),
        body: list.length ? h("div", { class: "card-body" }, h("div", { class: "bars" }, shown.map((p) =>
          // Selecting a product narrows the stock table below to it.
          h("button", { class: "bar-row", type: "button", "aria-pressed": String(params.q === p.name), "data-fk": `sv-${p.code}`,
            onclick: () => app.setParams({ q: params.q === p.name ? "" : p.name, layout: "product", product: "", store_sel: "" }) },
            h("span", { class: "bar-label" }, p.name, note(p) ? h("small", {}, note(p)) : null),
            h("span", { class: "bar-pair" },
              h("span", { class: "bar-line" },
                h("span", { class: "bar-stack", style: pct(p.available + p.reserved) },
                  h("i", { class: "wh", style: `flex:${p.available}` }), h("i", { class: "res", style: `flex:${p.reserved}` })),
                h("span", { class: "bar-val" }, `${fmt.num(p.available)} available${p.reserved ? ` + ${fmt.num(p.reserved)} reserved` : ""}`)),
              h("span", { class: "bar-line" },
                h("span", { class: "bar web", style: pct(Math.max(0, p.sold)) }),
                h("span", { class: "bar-val" }, `${fmt.num(p.sold)} sold`))))))) : noMatch(),
        foot: list.length > SHOWN ? h("button", { class: "btn-link", type: "button", onclick: () => { expanded = !expanded; render(); } },
          expanded ? `Show the ${SHOWN} with least stock` : `Show all ${list.length} products`) : null,
      });
    }

    loadStock().catch(() => {});
    loadEvents();
    return {
      update(next) {
        params = next;
        render();
        loadEvents();
      },
      reload: async () => {
        await loadStock();
        await loadEvents({ force: true });
      },
    };
  },
};
