// Website stock (Report 2: online staleness and sync): is the website showing
// what the stores really have, when does it next sync, and what did each
// refresh correct?

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, table, errorState, keepFocus, duration, countdown, syncTicker } from "../components/ui.js";

const STATUS = {
  higher: { label: "Website too high", kind: "danger" },
  lower: { label: "Website too low", kind: "warning" },
  equal: { label: "Correct", kind: "success" },
};

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    let stock = null;      // /website-stock response
    let sync = null;       // /sync/latest?sync_id= response for the opened refresh
    let syncError = null;
    let error = null;
    let token = 0, syncToken = 0;

    syncTicker(root, app, () => stock?.data?.staleness);

    async function loadAll() {
      const my = ++token;
      error = null;
      render();
      try {
        const s = await get("/website-stock");
        if (my !== token) return;
        stock = s;
        app.markRead(s.meta);
        if (params.sync) loadSync();
      } catch (err) {
        if (my !== token) return;
        error = err;
        render();
        throw err;
      }
      render();
    }

    // What one refresh corrected; opened from a Refresh history row.
    async function loadSync() {
      const my = ++syncToken, id = params.sync;
      sync = null; syncError = null;
      render();
      try {
        const r = await get("/sync/latest", { sync_id: id });
        if (my !== syncToken) return;
        sync = r;
      } catch (err) {
        if (my !== syncToken) return;
        syncError = err;
      }
      render();
    }

    function filtered() {
      const q = (params.q || "").toLowerCase();
      return stock.data.comparison.filter((r) =>
        (!params.cat || r.category === params.cat) &&
        (!q || r.product_name.toLowerCase().includes(q) || r.product_code.toLowerCase().includes(q)));
    }

    function render() { keepFocus(root, draw); }

    function draw() {
      clear(root);
      root.append(h("div", { class: "page-head" },
        h("div", {}, h("h1", {}, "Website stock"))));
      if (error) { root.append(card({ label: "Error", body: errorState(error, () => loadAll().catch(() => {})) })); return; }
      if (!stock) { root.append(card({ label: "Loading", body: loading("Loading website stock") })); return; }
      const all = stock.data.comparison;
      const wrong = all.filter((r) => r.comparison !== "equal");
      root.append(statusLine(), summary(all, wrong));
      // Refresh history answers the owner's question (is the interval short enough?), so it comes first.
      root.append(h("div", { class: "stack" }, wrong.length ? wrongCard(wrong) : null, historyCard(), allProductsCard(all)));
    }

    function statusLine() {
      const st = stock.data.staleness;
      const running = st.scheduler_status === "running";
      return h("div", { class: "status-line" },
        h("span", {}, "Automatic refresh: ",
          running
            ? [h("b", {}, `every ${duration(st.interval_seconds)}`), " · next in ",
               h("b", { "data-until": st.next_sync_at }, countdown(st.next_sync_at))]
            : h("b", {}, "not running")),
        h("span", {}, "Last refresh: ",
          st.last_sync_at ? h("b", { "data-ago": st.last_sync_at }, fmt.ago(st.last_sync_at)) : h("b", {}, "none yet")));
    }

    function summary(all, wrong) {
      if (!wrong.length) {
        return h("div", { class: "banner ok summary-big" },
          `The website matches the stores for all ${all.length} products.`);
      }
      const high = wrong.filter((r) => r.difference > 0).length;
      const low = wrong.length - high;
      const parts = [];
      if (high) parts.push(`${high} too high (customers may order stock that has gone)`);
      if (low) parts.push(`${low} too low (stock in the stores can't be sold online)`);
      return h("div", { class: "banner warn summary-big" },
        `${wrong.length} of ${all.length} products show the wrong stock on the website: ${parts.join("; ")}. The next refresh will correct them.`);
    }

    function stockTable(rows, caption) {
      return table({
        caption,
        columns: [
          { label: "Product", render: (r) => r.product_name, sub: (r) => `${r.product_code} · ${r.category}` },
          { label: "Website shows", num: true, render: (r) => fmt.num(r.online_shown) },
          { label: "Stores have", num: true, render: (r) => fmt.num(r.actual_in_store) },
          { label: "Difference", num: true, render: (r) => (r.difference ? fmt.signed(r.difference) : "—") },
          { label: "", render: (r) => badge(STATUS[r.comparison].label, STATUS[r.comparison].kind) },
        ],
        rows, rowKey: (r) => r.product_code,
        onSelect: (r) => app.navigate("inventory", { q: r.product_name, layout: "product" }),
        empty: state("", "No products match", ""),
      });
    }

    function wrongCard(wrong) {
      return card({
        id: "wrong", title: "Products with the wrong number on the website",
        body: stockTable(wrong, "Products whose website number differs from the stores"),
      });
    }

    function allProductsCard(all) {
      const cats = [{ value: "", label: "All categories" }, ...[...new Set(all.map((r) => r.category))].sort().map((c) => ({ value: c, label: c }))];
      const search = h("input", { type: "search", "data-fk": "q", value: params.q || "", placeholder: "Name or code, e.g. P018" });
      let t;
      search.addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => app.setParams({ q: search.value.trim() }), 200); });
      const rows = filtered();
      const det = h("details", { class: "card", open: params.q || params.cat ? true : undefined },
        h("summary", { class: "card-head", style: "cursor:pointer;padding-bottom:16px" },
          h("div", {}, h("h2", {}, `All products (${all.length})`)),
          h("span", { class: "btn btn-small summary-toggle", "aria-hidden": "true" })),
        h("div", { class: "card-body", style: "padding-top:0" },
          h("div", { class: "filters", role: "search", "aria-label": "Filter products", style: "margin:0" },
            field("Product", search, { wide: true }),
            field("Category", select(cats, params.cat || "", (v) => app.setParams({ cat: v }), { "data-fk": "cat" })))),
        stockTable(rows, "Website number compared with store stock, per product"));
      return det;
    }

    function refreshDetail() {
      if (syncError) return errorState(syncError, () => loadSync());
      if (!sync) return loading();
      const changes = sync.data.website_changes;
      return changes.length
        ? table({
            caption: "Website numbers changed by this refresh",
            columns: [
              { label: "Product", render: (r) => r.product_name },
              { label: "Website before", num: true, render: (r) => fmt.num(r.before_qty) },
              { label: "Website after", num: true, render: (r) => fmt.num(r.after_qty) },
              { label: "Change", num: true, render: (r) => fmt.signed(r.change) },
            ],
            rows: changes,
          })
        : h("p", { class: "secondary", style: "padding:12px 0 0;margin:0" }, "Nothing needed correcting: the website was already right.");
    }

    // ---------- is the refresh interval short enough? ----------
    // Time between refreshes: minutes when scheduled, hours or days in the sample data.
    function gap(sec) {
      if (sec === null || sec === undefined) return "—";
      if (sec < 3600) return duration(sec);
      if (sec < 172800) return `${Math.round(sec / 3600)} h`;
      return `${Math.round(sec / 86400)} days`;
    }

    function historyCard() {
      const rows = stock.data.history;
      return card({
        id: "refresh-history", title: "Refresh history",
        body: table({
          caption: "Website numbers each refresh corrected",
          columns: [
            { label: "Refresh", render: (r) => fmt.dateTime(r.run_at) },
            { label: "Since previous", num: true, render: (r) => gap(r.since_previous_seconds) },
            { label: "Stock changes in between", num: true, render: (r) => fmt.num(r.stock_events_since_previous) },
            { label: "Website numbers corrected", num: true, render: (r) => fmt.num(r.website_numbers_corrected) },
            { label: "Too high", num: true, render: (r) => (r.products_too_high ? `${r.products_too_high} (${fmt.units(r.units_overstated)})` : "—") },
            { label: "Too low", num: true, render: (r) => (r.products_too_low ? `${r.products_too_low} (${fmt.units(r.units_understated)})` : "—") },
          ],
          rows, rowKey: (r) => String(r.sync_id), selectedKey: params.sync,
          onSelect: (r) => app.setParams({ sync: params.sync === String(r.sync_id) ? "" : String(r.sync_id) }),
          detail: refreshDetail,
          empty: state("", "No refresh has run yet", ""),
        }),
        foot: "Too high = customers could order stock that had gone. Too low = stock in the stores could not be sold online. Stock changes = sales, deliveries and orders recorded since the previous refresh.",
      });
    }

    loadAll().catch(() => {});
    return {
      update(next) {
        const reopen = next.sync !== params.sync;
        params = next;
        if (reopen && next.sync) loadSync(); else render();
      },
      reload: () => loadAll(),
    };
  },
};
