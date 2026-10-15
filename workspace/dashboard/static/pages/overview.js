// Overview (UC1, owner): how the business did in the last 7 days, what the stock problem
// cost, which products sell best, and which store has a problem. Shelf and order detail
// stay on the store managers' and store staff's pages; the potential lost sales are a
// card on this page.

import { get } from "../api.js";
import lostSales from "./checkout.js";
import { h, clear, fmt, card, state, loading, errorState, keepFocus, duration, countdown, syncTicker, SYNC_TRIGGER } from "../components/ui.js";

const money = new Intl.NumberFormat("en-AU", { style: "currency", currency: "AUD", maximumFractionDigits: 0 });
const pct = new Intl.NumberFormat("en-AU", { style: "percent", maximumFractionDigits: 0 });
const plural = (n, one, many) => `${fmt.num(n)} ${n === 1 ? one : many}`;

export default {
  mount(root, app, initialParams) {
    let data = null, error = null, token = 0;
    // The lost sales card sits under Needs attention; a selected checkout opens full width below.
    const top = h("div"), lostRoot = h("div", { id: "lost-sales" }), detailRoot = h("div", { class: "page-section" });
    root.append(top, detailRoot);
    const lost = lostSales.mount(lostRoot, app, initialParams, { detailRoot });
    const LOST_RESET = { pickup: "", attempt: "", event: "" };
    // Show the lost sales card, optionally filtered to one pickup store.
    const showLost = (patch = {}) => (e) => {
      e.preventDefault();
      app.setParams({ ...LOST_RESET, ...patch });
      lostRoot.scrollIntoView({ behavior: "smooth", block: "start" });
    };

    syncTicker(top, app, () => data?.sync);

    async function load() {
      const my = ++token;
      error = null;
      try {
        const r = await get("/overview");
        if (my !== token) return;
        data = r.data;
        app.markRead(r.meta);
      } catch (err) {
        if (my !== token) return;
        error = err;
        render();
        throw err;
      }
      render();
    }

    function render() { keepFocus(top, draw); }

    function draw() {
      const root = clear(top);
      root.append(h("div", { class: "page-head" },
        h("div", {}, h("h1", {}, "Overview"))));
      if (error) return root.append(card({ label: "Error", body: errorState(error, () => load().catch(() => {})) }));
      if (!data) return root.append(card({ label: "Loading", body: loading("Loading overview") }));
      root.append(kpis(), h("div", { class: "overview-grid owner" },
        h("div", { class: "overview-col" }, attention(), lostRoot), bestSellers()));
    }

    // ---------- headline numbers ----------
    function tile({ label, value, note, tone, page, params, onclick }) {
      return h("a", { class: `kpi ${tone}`, href: `#/${page}${params ? `?${params}` : ""}`, onclick },
        h("span", { class: "kpi-label" }, label),
        h("strong", { class: "kpi-value" }, value),
        note ? h("span", { class: "kpi-note" }, note) : null);
    }

    function kpis() {
      const { website: w, sync: s, lost_sales: l, sales_7_days: sales, out_of_stock: oos } = data;
      const running = s.scheduler_status === "running";
      const store = sales["in-store"], online = sales.online;
      return h("div", { class: "kpis" },
        tile({ label: "Sales", page: "inventory",
          value: money.format(store.value + online.value),
          note: `in-store ${money.format(store.value)} · online ${money.format(online.value)}`,
          tone: "neutral" }),
        tile({ label: "Potential lost sales", page: "overview", onclick: showLost(),
          value: money.format(l.value),
          note: l.units
            ? `${pct.format(l.share_of_online_demand)} of online demand`
            : "No checkout was blocked",
          tone: l.units ? "bad" : "good" }),
        tile({ label: "Out of stock", page: "inventory", params: "low=1",
          value: `${fmt.num(oos.shelves)} shel${oos.shelves === 1 ? "f" : "ves"}`,
          note: oos.shelves ? `in ${plural(oos.stores, "store", "stores")}` : "every store has every product",
          tone: oos.shelves ? "bad" : "good" }),
        tile({ label: "Website accuracy", page: "website",
          value: w.out_of_date ? `${w.out_of_date} wrong` : "All correct",
          note: w.out_of_date ? `of ${w.products} products show the wrong stock` : `${w.products} of ${w.products} products match the stores`,
          tone: w.out_of_date ? "bad" : "good" }),
        tile({ label: "Next website refresh", page: "website",
          value: running ? h("span", { "data-until": s.next_sync_at }, countdown(s.next_sync_at)) : "Not running",
          note: running ? `every ${duration(s.interval_seconds)} · last ${fmt.time(s.last_sync_at)} (${SYNC_TRIGGER[s.last_sync_trigger] || s.last_sync_trigger})`
                        : "website only updates on a manual refresh",
          tone: running ? "good" : "warn" }));
    }

    // ---------- which part of the business needs the owner ----------
    function attention() {
      const { website: w, quality: q, stores } = data;
      const items = [];
      if (w.out_of_date)
        items.push(h("li", { class: "todo-bad" }, dot(), h("span", { class: "todo-text" }, `${plural(w.out_of_date, "product shows", "products show")} the wrong stock on the website`),
          h("a", { href: "#/website" }, "See website stock")));
      if (q.incomplete)
        items.push(h("li", { class: "todo-warn" }, dot(), h("span", { class: "todo-text" },
          `${plural(q.rejected_rows + q.mismatched_pairs, "record", "records")} could not be loaded into the reports`)));
      for (const st of stores) {
        const issues = [];
        if (st.blocked) issues.push(h("a", { href: `#/overview?pickup=${st.store_code}`, onclick: showLost({ pickup: st.store_code }) }, plural(st.blocked, "checkout blocked", "checkouts blocked")));
        if (st.out_of_stock) issues.push(h("a", { href: `#/inventory?store=${st.store_code}&low=1` }, plural(st.out_of_stock, "product out of stock", "products out of stock")));
        if (st.overdue_orders) issues.push(h("a", { href: `#/orders?store=${st.store_code}&overdue=1` }, plural(st.overdue_orders, "order overdue", "orders overdue")));
        items.push(h("li", { class: st.blocked || st.overdue_orders ? "todo-bad" : "todo-warn" }, dot(),
          h("span", { class: "todo-text" }, h("b", {}, st.store_name.replace("PetHaven ", ""))),
          h("span", { class: "todo-links" }, issues.flatMap((a, n) => (n ? [" · ", a] : [a])))));
      }
      return card({
        id: "attention", title: "Needs attention",
        body: items.length
          ? h("ul", { class: "todo" }, items)
          : state("", "All stores are running normally", "The website matches the stores, and no store has a blocked checkout, an empty shelf or an overdue order."),
      });
    }

    function dot() { return h("span", { class: "todo-dot", "aria-hidden": "true" }); }

    // ---------- what sells ----------
    function bestSellers() {
      const rows = data.best_sellers;
      const max = Math.max(1, ...rows.map((r) => r.units));
      return card({
        id: "best-sellers", title: "Best sellers",
        actions: h("a", { href: "#/inventory" }, "Stock and sales"),
        body: rows.length
          ? h("div", { class: "bs" },
              h("div", { class: "bs-legend", "aria-hidden": "true" },
                h("span", {}, h("i", { class: "bs-swatch bs-swatch-store" }), "In-store"),
                h("span", {}, h("i", { class: "bs-swatch bs-swatch-online" }), "Online")),
              h("ol", { class: "bs-list" }, rows.map((r) => h("li", { class: "bs-row" },
                h("span", { class: "bs-name" }, r.product_name, r.out_of_stock_stores ? h("span", { class: "cell-sub" },
                  h("a", { class: "bs-flag", href: `#/inventory?q=${encodeURIComponent(r.product_name)}&layout=product` },
                    `out of stock in ${r.out_of_stock_stores} of ${data.store_count} stores`)) : null),
                h("span", { class: "bs-track", role: "img", "aria-label": `${r.in_store} in-store, ${r.online} online` },
                  h("span", { class: "bs-store", style: `width:${(r.in_store / max) * 100}%` }),
                  h("span", { class: "bs-online", style: `width:${(r.online / max) * 100}%` })),
                h("span", { class: "bs-value" }, fmt.units(r.units),
                  h("span", { class: "cell-sub" }, money.format(r.value)))))))
          : state("", "No sales in the last 7 days", ""),
      });
    }

    load().catch(() => {});
    // Arriving from a link to a lost sale: start at that card.
    if (initialParams.pickup || initialParams.attempt) setTimeout(() => lostRoot.scrollIntoView({ block: "start" }), 300);
    return {
      update(next) { render(); lost.update(next); },
      reload: () => Promise.all([load(), lost.reload()]),
    };
  },
};
