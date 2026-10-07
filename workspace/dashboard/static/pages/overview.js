// Overview: the admin's start page. What needs attention right now, in a few
// numbers, each linking to the page with the detail.

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, table, errorState, keepFocus, duration, countdown, syncTicker, SYNC_TRIGGER } from "../components/ui.js";

const REASON = { stale: "Website number was out of date", split: "No single store had enough" };

export default {
  mount(root, app) {
    let data = null, error = null, token = 0;

    syncTicker(root, app, () => data?.sync);

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

    function render() { keepFocus(root, draw); }

    function draw() {
      clear(root);
      root.append(h("div", { class: "page-head" },
        h("div", {}, h("h1", {}, "Overview"),
          h("p", { class: "subtitle" }, "What needs your attention across the five stores and the website."))));
      if (error) return root.append(card({ label: "Error", body: errorState(error, () => load().catch(() => {})) }));
      if (!data) return root.append(card({ label: "Loading", body: loading("Loading overview") }));
      root.append(kpis(), h("div", { class: "overview-grid" }, h("div", { class: "stack" }, attention(), lostCard()), stockCard()));
    }

    // ---------- headline numbers ----------
    function tile({ label, value, note, tone, page, params }) {
      return h("a", { class: `kpi ${tone}`, href: `#/${page}${params ? `?${params}` : ""}` },
        h("span", { class: "kpi-label" }, label),
        h("strong", { class: "kpi-value" }, value),
        h("span", { class: "kpi-note" }, note));
    }

    function kpis() {
      const { website: w, sync: s, stock: st, lost_sales: l, orders: o, sales_7_days: sales } = data;
      const running = s.scheduler_status === "running";
      return h("div", { class: "kpis" },
        tile({ label: "Website accuracy", page: "website",
          value: w.out_of_date ? `${w.out_of_date} wrong` : "All correct",
          note: w.out_of_date ? `of ${w.products} products show the wrong stock` : `${w.products} of ${w.products} products match the stores`,
          tone: w.out_of_date ? "bad" : "good" }),
        tile({ label: "Next website sync", page: "website",
          value: running ? h("span", { "data-until": s.next_sync_at }, countdown(s.next_sync_at)) : "Not running",
          note: running ? `every ${duration(s.interval_seconds)} · last ${fmt.time(s.last_sync_at)} (${SYNC_TRIGGER[s.last_sync_trigger] || s.last_sync_trigger})`
                        : "website only updates on a manual sync",
          tone: running ? "good" : "warn" }),
        tile({ label: "Stock alerts", page: "inventory", params: "low=1",
          value: `${st.out_of_stock} out · ${st.low_stock} low`,
          note: "store shelves with 0 or 1–2 left",
          tone: st.out_of_stock ? "bad" : st.low_stock ? "warn" : "good" }),
        tile({ label: "Lost sales (7 days)", page: "checkout",
          value: `${l.units} unit${l.units === 1 ? "" : "s"}`,
          note: `${l.items} item${l.items === 1 ? "" : "s"} blocked at checkout`,
          tone: l.items ? "warn" : "good" }),
        tile({ label: "Click & collect", page: "checkout", params: "tab=reservations",
          value: `${o.open_orders} open`,
          note: `${o.ready} ready · ${o.not_ready} on the way${o.overdue ? ` · ${o.overdue} overdue` : ""}`,
          tone: o.overdue ? "bad" : "good" }),
        tile({ label: "Units sold (7 days)", page: "inventory", params: "view=sales",
          value: fmt.num((sales["in-store"] || 0) + (sales.online || 0)),
          note: `${fmt.num(sales["in-store"] || 0)} in-store · ${fmt.num(sales.online || 0)} online`,
          tone: "neutral" }));
    }

    // ---------- to-do list ----------
    function attention() {
      const { website: w, sync: s, stock: st, orders: o, quality: q } = data;
      const items = [];
      const add = (tone, text, link, page, params) => items.push({ tone, text, link, page, params });
      if (w.out_of_date) add("bad", `${w.out_of_date} product${w.out_of_date === 1 ? " shows" : "s show"} the wrong stock on the website`, "Check website stock", "website", "");
      if (s.scheduler_status !== "running") add("warn", "The automatic website sync is not running", "See website stock", "website", "");
      if (o.overdue) add("bad", `${o.overdue} click & collect order${o.overdue === 1 ? " has" : "s have"} not been collected for over 3 days`, "View orders", "checkout", "tab=reservations&overdue=1");
      if (st.out_of_stock) add("bad", `${st.out_of_stock} store shel${st.out_of_stock === 1 ? "f is" : "ves are"} out of stock`, "View stock", "inventory", "low=1");
      if (st.low_stock) add("warn", `${st.low_stock} store shel${st.low_stock === 1 ? "f is" : "ves are"} running low (1–2 left)`, "View stock", "inventory", "low=1");
      if (o.not_ready) add("info", `${o.not_ready} click & collect order${o.not_ready === 1 ? " is" : "s are"} waiting for items from another store`, "View orders", "checkout", "tab=reservations");
      if (q.incomplete) add("warn", `${q.rejected_rows + q.mismatched_pairs} record${q.rejected_rows + q.mismatched_pairs === 1 ? "" : "s"} could not be loaded into the reports`, "View data checks", "integration", "");
      return card({
        id: "attention", title: "Needs attention",
        body: items.length
          ? h("ul", { class: "todo" }, items.map((i) => h("li", { class: `todo-${i.tone}` },
              h("span", { class: "todo-dot", "aria-hidden": "true" }),
              h("span", { class: "todo-text" }, i.text),
              h("a", { href: `#/${i.page}${i.params ? `?${i.params}` : ""}` }, i.link))))
          : state("", "Nothing needs attention", "The website matches the stores, and there are no stock or order problems."),
      });
    }

    function stockCard() {
      const rows = data.stock.rows;
      return card({
        id: "low-stock", title: "Out of stock and running low",
        actions: h("a", { href: "#/inventory?low=1" }, "All stock alerts"),
        body: table({
          caption: "Store shelves with 2 or fewer units",
          columns: [
            { label: "Product", render: (r) => r.product_name, sub: (r) => r.product_code },
            { label: "Store", render: (r) => r.store_name.replace("PetHaven ", "") },
            { label: "On shelf", num: true, render: (r) => (r.available === 0 ? badge("0", "danger") : badge(String(r.available), "warning")) },
          ],
          rows, empty: state("", "No stock alerts", "Every store has at least 3 of every product."),
        }),
      });
    }

    function lostCard() {
      const rows = data.lost_sales.rows;
      return card({
        id: "lost-sales", title: "Latest lost sales",
        actions: h("a", { href: "#/checkout" }, "All lost sales"),
        body: table({
          caption: "Latest items customers could not buy at checkout",
          columns: [
            { label: "When", render: (r) => fmt.dateTime(r.attempted_at) },
            { label: "Product", render: (r) => r.product_name, sub: (r) => `${r.units} unit${r.units === 1 ? "" : "s"} · ${r.pickup_store.replace("PetHaven ", "")}` },
            { label: "Why", render: (r) => REASON[r.reason_code] },
          ],
          rows, empty: state("", "No lost sales recorded", ""),
        }),
      });
    }

    load().catch(() => {});
    return { update() { render(); }, reload: () => load() };
  },
};
