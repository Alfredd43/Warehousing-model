// Website stock (Report 2: online staleness and sync): is the website showing
// what the stores really have, when does it next sync, and what did the last
// sync correct?

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, table, kv, errorState, keepFocus, duration, countdown, syncTicker, SYNC_TRIGGER } from "../components/ui.js";

const STATUS = {
  higher: { label: "Website too high", kind: "danger" },
  lower: { label: "Website too low", kind: "warning" },
  equal: { label: "Correct", kind: "success" },
};

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    let stock = null;      // /website-stock response
    let sync = null;       // /sync/latest response
    let error = null;
    let token = 0;

    syncTicker(root, app, () => stock?.data?.staleness);

    async function loadAll() {
      const my = ++token;
      error = null;
      render();
      try {
        const [s, y] = await Promise.all([get("/website-stock"), get("/sync/latest")]);
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
        h("div", {}, h("h1", {}, "Website stock"),
          h("p", { class: "subtitle" }, "Does the website show what the stores really have?"))));
      if (error) { root.append(card({ label: "Error", body: errorState(error, () => loadAll().catch(() => {})) })); return; }
      if (!stock) { root.append(card({ label: "Loading", body: loading("Loading website stock") })); return; }
      const all = stock.data.comparison;
      const wrong = all.filter((r) => r.comparison !== "equal");
      root.append(statusLine(), summary(all, wrong));
      root.append(h("div", { class: "stack" }, wrong.length ? wrongCard(wrong) : null, allProductsCard(all), syncCard()));
    }

    function statusLine() {
      const st = stock.data.staleness;
      const running = st.scheduler_status === "running";
      return h("div", { class: "status-line" },
        h("span", {}, "Automatic sync: ",
          running
            ? [h("b", {}, `every ${duration(st.interval_seconds)}`), " · next in ",
               h("b", { "data-until": st.next_sync_at }, countdown(st.next_sync_at))]
            : [h("b", {}, "not running"), " — the website only updates on a manual sync"]),
        h("span", {}, "Last sync: ",
          st.last_sync_at ? [h("b", {}, fmt.time(st.last_sync_at)), " (",
            h("span", { "data-ago": st.last_sync_at }, fmt.ago(st.last_sync_at)),
            `, ${SYNC_TRIGGER[st.last_sync_trigger] || st.last_sync_trigger})`] : h("b", {}, "none yet")));
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
        `${wrong.length} of ${all.length} products show the wrong stock on the website: ${parts.join("; ")}. The next sync will correct them.`);
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
        onSelect: (r) => app.navigate("inventory", { product: r.product_code }),
        empty: state("", "No products match", ""),
      });
    }

    function wrongCard(wrong) {
      return card({
        id: "wrong", title: "Products with the wrong number on the website",
        subtitle: "Select a product to see its stock in each store.",
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
          h("div", {}, h("h2", {}, `All products (${all.length})`), h("p", {}, "Website number next to what the five stores have free to sell.")),
          h("span", { class: "btn btn-small summary-toggle", "aria-hidden": "true" })),
        h("div", { class: "card-body", style: "padding-top:0" },
          h("div", { class: "filters", role: "search", "aria-label": "Filter products", style: "margin:0" },
            field("Product", search, { wide: true }),
            field("Category", select(cats, params.cat || "", (v) => app.setParams({ cat: v }), { "data-fk": "cat" })))),
        stockTable(rows, "Website number compared with store stock, per product"));
      return det;
    }

    function syncCard() {
      if (!sync) return card({ id: "latest-sync", title: "Last sync", body: loading() });
      const d = sync.data;
      if (!d.run) return card({ id: "latest-sync", title: "Last sync", body: state("", "No sync has run yet", "") });
      return card({
        id: "latest-sync", title: "What the last sync corrected",
        body: h("div", {},
          h("div", { class: "card-body", style: "padding-bottom:8px" }, kv([
            ["Ran at", `${fmt.dateTime(d.run.run_at)} (${SYNC_TRIGGER[d.run.triggered_by] || d.run.triggered_by})`],
            ["Website numbers corrected", fmt.num(d.website_changes.length)],
          ])),
          d.website_changes.length
            ? table({
                caption: "Website numbers changed by the last sync",
                columns: [
                  { label: "Product", render: (r) => r.product_name, sub: (r) => r.product_code },
                  { label: "Website before", num: true, render: (r) => fmt.num(r.before_qty) },
                  { label: "Website after", num: true, render: (r) => fmt.num(r.after_qty) },
                  { label: "Change", num: true, render: (r) => fmt.signed(r.change) },
                ],
                rows: d.website_changes,
              })
            : h("p", { class: "secondary", style: "padding:0 20px 18px" }, "Nothing needed correcting: the website was already right.")),
      });
    }

    loadAll().catch(() => {});
    return {
      update(next) { params = next; render(); },
      reload: () => loadAll(),
    };
  },
};
