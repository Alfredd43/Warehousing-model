// Page A: Website & Sync (required Report 2: online staleness and sync).

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, segmented, table, kv, errorState, keepFocus } from "../components/ui.js";

const CHART_LIMIT = 8;

const STATUS = {
  higher: { label: "Website higher", kind: "warning" },
  lower: { label: "Website lower", kind: "info" },
  equal: { label: "Equal", kind: "neutral" },
};

const FILTERS = [
  { value: "all", label: "All" },
  { value: "different", label: "Different" },
  { value: "higher", label: "Website higher" },
  { value: "lower", label: "Website lower" },
];

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    let stock = null;      // /website-stock response
    let sync = null;       // /sync/latest response
    let error = null;
    let token = 0;
    let syncToken = 0;

    async function loadAll() {
      const my = ++token;
      error = null;
      render();
      try {
        const [s, y] = await Promise.all([get("/website-stock"), get("/sync/latest", { sync_id: params.sync })]);
        if (my !== token) return;
        stock = s; sync = y;
        app.markRead(s.meta);
      } catch (err) {
        if (my !== token) return;
        error = err;
        render();
        throw err;
      }
      render();
    }

    async function loadSync() {
      const my = ++syncToken;
      try {
        const y = await get("/sync/latest", { sync_id: params.sync });
        if (my !== syncToken) return;
        sync = y;
      } catch (err) {
        if (my !== syncToken) return;
        sync = { error: err };
      }
      render();
    }

    function filtered() {
      const q = (params.q || "").toLowerCase();
      const status = params.status || "all";
      return stock.data.comparison.filter((r) =>
        (!params.cat || r.category === params.cat) &&
        (!q || r.product_name.toLowerCase().includes(q) || r.product_code.toLowerCase().includes(q)) &&
        (status === "all" || (status === "different" ? r.comparison !== "equal" : r.comparison === status)));
    }

    function render() { keepFocus(root, draw); }

    function draw() {
      clear(root);
      root.append(head());
      if (error) { root.append(card({ label: "Error", body: errorState(error, () => loadAll().catch(() => {})) })); return; }
      if (!stock) { root.append(card({ label: "Loading", body: loading("Loading website comparison") })); return; }
      const rows = filtered();
      const all = stock.data.comparison;
      const selected = rows.find((r) => r.product_code === params.product) || rows[0] || null;
      root.append(statusLine(), filters(), lede(all, rows));
      root.append(h("div", { class: "grid grid-2", style: "margin-bottom:22px" }, chartCard(rows, selected), detailCard(selected)));
      root.append(h("div", { class: "stack" }, tableCard(rows, selected), syncCard(), storeChangesCard()));
    }

    function head() {
      return h("div", { class: "page-head" },
        h("div", {},
          h("h1", {}, "Website & Sync"),
          h("p", { class: "subtitle" }, "Compare website availability with warehouse stock and inspect the latest sync."),
          h("span", { class: "report-id" }, "Required report 2 · Online staleness and sync")));
    }

    function statusLine() {
      const st = stock.data.staleness;
      const q = stock.data.quality;
      return h("div", { class: "status-line" },
        h("span", {}, "Last website sync: ",
          st.last_sync_at ? h("b", {}, fmt.dateTime(st.last_sync_at)) : h("b", {}, "none recorded"),
          st.last_sync_at ? ` (${fmt.ago(st.last_sync_at)})` : ""),
        h("span", {}, "Report read: ", h("b", {}, fmt.dateTimeSec(stock.meta.read_at))),
        h("span", {}, "Data quality: ", q.incomplete
          ? h("a", { href: "#/integration" }, badge("Review needed", "warning"))
          : badge(`${q.matching_pairs} of ${q.compared_pairs} pairs match`, "success")));
    }

    function filters() {
      const cats = [{ value: "", label: "All categories" }, ...[...new Set(stock.data.comparison.map((r) => r.category))].sort().map((c) => ({ value: c, label: c }))];
      const search = h("input", { type: "search", "data-fk": "q", value: params.q || "", placeholder: "Name or code, e.g. P018", "aria-describedby": "website-search-help" });
      let t;
      search.addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => app.setParams({ q: search.value.trim() }), 200); });
      const any = params.q || params.cat || (params.status && params.status !== "all");
      return h("div", { class: "filters", role: "search", "aria-label": "Filter products" },
        field("Product", search, { wide: true }),
        h("span", { id: "website-search-help", class: "sr-only" }, "Filters the comparison chart and table"),
        field("Category", select(cats, params.cat || "", (v) => app.setParams({ cat: v }), { "data-fk": "cat" })),
        segmented("Comparison", FILTERS, params.status || "all", (v) => app.setParams({ status: v === "all" ? "" : v })),
        any ? h("button", { class: "btn", type: "button", onclick: () => app.setParams({ q: "", cat: "", status: "" }) }, "Clear filters") : null);
    }

    function lede(all, rows) {
      const differ = all.filter((r) => r.comparison !== "equal").length;
      const st = stock.data.staleness;
      const filteredNote = rows.length !== all.length ? ` Showing ${rows.length} after filters.` : "";
      return h("div", { class: "lede" },
        h("p", {}, h("b", {}, `${differ} of ${all.length}`), " mapped online products differ from warehouse availability.", filteredNote),
        st.last_sync_at ? h("p", { class: "secondary small", style: "margin-top:4px" },
          `${fmt.num(st.pending_events)} stock events recorded since the last sync (${st.pending_sales} in-store sale lines, ` +
          `${st.pending_deliveries} delivery lines, ${st.pending_order_events} order steps, ${st.pending_checkout_blocks} blocked items). ` +
          "Not every event changes a website number.") : null,
        stock.meta.warnings.map((w) => h("p", { class: "secondary small" }, w)));
    }

    function chartCard(rows, selected) {
      const shown = rows.slice(0, CHART_LIMIT);
      const max = Math.max(1, ...shown.flatMap((r) => [r.online_shown, r.actual_in_store]));
      const pct = (n) => `${Math.max(0, (n / max) * 100)}%`;
      const allEqual = shown.length && shown.every((r) => r.comparison === "equal");
      const body = shown.length
        ? h("div", { class: "card-body" },
            allEqual ? h("div", { class: "banner ok", style: "margin-bottom:12px" }, "All displayed products match: the website shows what the stores have free to sell.") : null,
            h("div", { class: "bars", role: "list", "aria-label": "Website shown and warehouse available, units" },
              shown.map((r) => h("button", {
                type: "button", class: "bar-row", role: "listitem", "data-fk": `bar-${r.product_code}`, "aria-pressed": String(selected?.product_code === r.product_code),
                "aria-label": `${r.product_name}: website ${r.online_shown}, warehouse ${r.actual_in_store}, difference ${fmt.signed(r.difference)} units`,
                onclick: () => app.setParams({ product: r.product_code }),
              },
              h("span", { class: "bar-label" }, r.product_name, h("small", {}, `${r.product_code} · `, STATUS[r.comparison].label, r.difference ? ` ${fmt.signed(r.difference)}` : "")),
              h("span", { class: "bar-pair", "aria-hidden": "true" },
                h("span", { class: "bar-line" }, h("span", { class: "bar web", style: `width:${pct(r.online_shown)}` }), h("span", { class: "bar-val" }, fmt.num(r.online_shown))),
                h("span", { class: "bar-line" }, h("span", { class: "bar wh", style: `width:${pct(r.actual_in_store)}` }), h("span", { class: "bar-val" }, fmt.num(r.actual_in_store))))))),
            h("p", { class: "axis-note" }, `Showing ${shown.length} of ${rows.length}, largest difference first. Scale: units, from 0 to ${fmt.num(max)}. The full table is below.`))
        : state("", "No products match these filters", "", h("button", { class: "btn", type: "button", onclick: () => app.setParams({ q: "", cat: "", status: "" }) }, "Clear filters"));
      return card({
        id: "comparison-chart", title: "Website vs warehouse available",
        subtitle: "One combined number per product across all five stores.",
        actions: h("div", { class: "legend" },
          h("span", {}, h("i", { class: "swatch", style: "background:var(--chart-website)" }), "Website shown"),
          h("span", {}, h("i", { class: "swatch", style: "background:var(--chart-warehouse)" }), "Warehouse available")),
        body,
      });
    }

    function detailCard(r) {
      if (!r) return card({ id: "product-detail", title: "Selected product", body: state("", "No product selected", "Choose a product in the chart or table.") });
      let sentence;
      if (r.difference > 0) sentence = `The website shows ${fmt.units(r.difference)} more than the stores have free to sell. Customers can add items to their bag that checkout will then block.`;
      else if (r.difference < 0) sentence = `The website shows ${fmt.units(-r.difference)} fewer than the stores have free to sell. Stock that is in the stores cannot be bought online.`;
      else sentence = "The website number equals warehouse availability for this product.";
      return card({
        id: "product-detail", title: "Selected product",
        body: h("div", { class: "card-body" },
          h("h3", {}, r.product_name),
          h("p", { class: "secondary small" }, `${r.product_code} · ${r.category}`),
          h("div", { class: "big-pair" },
            h("div", {}, h("strong", {}, fmt.num(r.online_shown)), h("span", {}, "Website shown")),
            h("div", {}, h("strong", {}, fmt.num(r.actual_in_store)), h("span", {}, "Warehouse available"))),
          h("p", { style: "margin-bottom:12px" }, badge(STATUS[r.comparison].label + (r.difference ? ` ${fmt.signed(r.difference)}` : ""), STATUS[r.comparison].kind), " ", sentence),
          kv([["Website last synced", fmt.dateTime(r.synced_at)], ["Scope", "All five stores combined"]]),
          h("div", { style: "margin-top:16px" },
            h("button", { class: "btn btn-accent", type: "button", onclick: () => app.navigate("inventory", { product: r.product_code }) }, "View stock by store"))),
      });
    }

    function tableCard(rows, selected) {
      return card({
        id: "comparison-table", title: "Complete product comparison",
        subtitle: "Difference = website shown − warehouse available, in units.",
        body: table({
          caption: "Website shown compared with warehouse available, per product",
          columns: [
            { label: "Product", render: (r) => r.product_name, sub: (r) => r.product_code },
            { label: "Category", key: "category" },
            { label: "Website shown", num: true, render: (r) => fmt.num(r.online_shown) },
            { label: "Warehouse available", num: true, render: (r) => fmt.num(r.actual_in_store) },
            { label: "Difference", num: true, render: (r) => fmt.signed(r.difference) },
            { label: "Status", render: (r) => badge(STATUS[r.comparison].label, STATUS[r.comparison].kind) },
          ],
          rows, rowKey: (r) => r.product_code, selectedKey: selected?.product_code,
          onSelect: (r) => app.setParams({ product: r.product_code }),
          empty: state("", "No products match these filters", ""),
        }),
        foot: "Website shown is read live from the online store; warehouse available is rebuilt from warehouse stock events. Products without an approved online mapping are not compared.",
      });
    }

    function syncCard() {
      if (!sync) return card({ id: "latest-sync", title: "Latest website sync", body: loading() });
      if (sync.error) return card({ id: "latest-sync", title: "Latest website sync", body: errorState(sync.error, loadSync) });
      const d = sync.data;
      if (!d.run) {
        return card({ id: "latest-sync", title: "Latest website sync",
          body: state("", "No website sync has been recorded", "Run one from the business demo.",
            h("button", { class: "btn btn-accent", type: "button", onclick: () => app.openDemo("sync") }, "Open sync action")) });
      }
      const runOptions = d.runs.map((r) => ({ value: r.sync_id, label: `Sync ${r.sync_id} · ${fmt.dateTime(r.run_at)}${r.sync_id === d.runs[0].sync_id ? " (latest)" : ""}` }));
      const picker = field("Sync batch", select(runOptions, d.run.sync_id, (v) => app.setParams({ sync: Number(v) === d.runs[0].sync_id ? "" : v }), { "data-fk": "sync" }), { wide: true });
      const body = h("div", {},
        h("div", { class: "card-body", style: "padding-bottom:12px" },
          !d.is_latest ? h("div", { class: "banner info" }, `You are viewing sync ${d.run.sync_id}, an earlier batch. Its before and after values are kept as recorded.`) : null,
          kv([
            ["Run at", fmt.dateTime(d.run.run_at)],
            ["Online store sync number", d.run.source_sync_no],
            ["Stock events since the previous sync", fmt.num(d.run.events_processed)],
            ["Website quantities changed", fmt.num(d.website_changes.length)],
          ])),
        d.website_changes.length
          ? table({
              caption: `Website quantities changed by sync ${d.run.sync_id}`,
              columns: [
                { label: "Product", render: (r) => r.product_name, sub: (r) => r.product_code },
                { label: "Website before", num: true, render: (r) => fmt.num(r.before_qty) },
                { label: "Website after", num: true, render: (r) => fmt.num(r.after_qty) },
                { label: "Change", num: true, render: (r) => fmt.signed(r.change) },
              ],
              rows: d.website_changes,
            })
          : state("", d.is_latest ? "The latest sync did not change any website quantities." : "This sync did not change any website quantities.", ""));
      return card({ id: "latest-sync", title: d.is_latest ? "Latest website sync" : `Website sync ${d.run.sync_id}`,
        subtitle: "Changed website values, before → after. The sync copies the store system's shelf totals to the website.",
        actions: picker, body });
    }

    function storeChangesCard() {
      if (!sync || sync.error || !sync.data.run) return null;
      const rows = sync.data.store_changes;
      const det = h("details", { class: "card" },
        h("summary", { class: "card-head", style: "cursor:pointer;padding-bottom:16px" },
          h("div", {}, h("h2", {}, `Store balance changes between syncs (${rows.length})`),
            h("p", {}, "These movements occurred through business operations; the sync recorded them.")),
          h("span", { class: "btn btn-small summary-toggle", "aria-hidden": "true" })),
        table({
          caption: "Store balances that changed between the previous sync and this one",
          columns: [
            { label: "Store", key: "store_name" },
            { label: "Product", render: (r) => r.product_name, sub: (r) => r.product_code },
            { label: "Measure", render: (r) => (r.measure === "in_store" ? "Available" : "Reserved") },
            { label: "Before", num: true, render: (r) => fmt.num(r.before_qty) },
            { label: "After", num: true, render: (r) => fmt.num(r.after_qty) },
            { label: "Change", num: true, render: (r) => fmt.signed(r.change) },
          ],
          rows, empty: state("", "No store balances changed between these syncs", ""),
        }));
      return det;
    }

    loadAll().catch(() => {});
    return {
      update(next) {
        const syncChanged = (next.sync || "") !== (params.sync || "");
        params = next;
        if (syncChanged && stock) loadSync(); else render();
      },
      reload: () => loadAll(),
    };
  },
};
