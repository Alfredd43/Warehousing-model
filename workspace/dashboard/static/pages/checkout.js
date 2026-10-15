// Potential lost sales (UC1, owner; Report 3): items blocked at checkout, with the
// customer's source checkout record. Shown as a card on the Overview page; the
// selected checkout opens in detailRoot (full width below the card's column).

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, table, kv, errorState, keepFocus } from "../components/ui.js";

const money = new Intl.NumberFormat("en-AU", { style: "currency", currency: "AUD" });

const REASON = { stale: "Website out of date", split: "No single store had enough" };
const SHOWN = 5;

export default {
  mount(root, app, initialParams, { detailRoot = root } = {}) {
    let params = initialParams;
    let blocked = null, blockedErr = null;
    let attempt = null, attemptErr = null, attemptKey = null;
    let token = 0, atToken = 0, showAll = false;

    async function loadLists() {
      const my = ++token;
      blockedErr = null;
      try {
        const b = await get("/checkout/blocked");
        if (my !== token) return;
        blocked = b;
        app.markRead(b.meta);
      } catch (err) {
        if (my !== token) return;
        blockedErr = err;
      }
      render();
      if (blockedErr) throw blockedErr;
    }

    async function loadAttempt(force = false) {
      const id = params.attempt;
      if (!id) { attempt = null; attemptKey = null; return; }
      if (!force && id === attemptKey) return;
      const my = ++atToken;
      attemptKey = id; attempt = null; attemptErr = null;
      render();
      setTimeout(() => detailRoot.scrollIntoView({ behavior: "smooth", block: "start" }), 50);
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

    function render() {
      keepFocus(root, draw);
      if (detailRoot !== root) keepFocus(detailRoot, drawDetail);
    }

    function draw() {
      clear(root);
      root.append(blockedCard());
      if (detailRoot === root) drawDetail();
    }

    function drawDetail() {
      if (detailRoot !== root) clear(detailRoot);
      if (params.attempt) detailRoot.append(attemptCard());
    }

    // ---------- blocked items: newest first, a pickup store from Needs attention ----------
    function blockedCard() {
      const head = { id: "blocked-table", title: "Potential lost sales" };
      if (blockedErr) return card({ ...head, body: errorState(blockedErr, () => loadLists().catch(() => {})) });
      if (!blocked) return card({ ...head, body: loading() });
      const all = blocked.data.rows;
      const rows = all.filter((r) => !params.pickup || r.pickup_store_code === params.pickup)
        .sort((a, b) => b.attempted_at.localeCompare(a.attempted_at));
      const store = params.pickup && all.find((r) => r.pickup_store_code === params.pickup);
      const shown = showAll ? rows : rows.slice(0, SHOWN);
      const units = rows.reduce((n, r) => n + (r.requested || 0), 0);
      const value = rows.reduce((n, r) => n + (r.value || 0), 0);
      const showAllStores = h("button", { class: "btn btn-small", type: "button", onclick: () => app.setParams({ pickup: "", attempt: "", event: "" }) }, "All stores");
      return card({
        ...head,
        subtitle: `${store ? `Pickup at ${store.pickup_store.replace("PetHaven ", "")} only. ` : ""}Online items no store could supply, newest first. Nobody was charged. Select one to see the checkout.`,
        actions: params.pickup ? showAllStores : null,
        body: h("div", {},
          table({
            caption: "Items blocked at checkout before payment",
            columns: [
              { label: "Product", render: (r) => r.product_name,
                sub: (r) => `${fmt.num(r.requested)} wanted · ${r.pickup_store.replace("PetHaven ", "")} · ${fmt.dateTime(r.attempted_at)}` },
              { label: "Why", render: (r) => badge(REASON[r.reason_code], r.reason_code === "stale" ? "warning" : "info"),
                sub: (r) => (r.reason_code === "stale"
                  ? `website showed ${fmt.num(r.website_shown_then)}, stores had ${fmt.num(r.combined_available_then)}`
                  : `stores had ${fmt.num(r.combined_available_then)} in total`) },
              { label: "Value", num: true, render: (r) => money.format(r.value) },
            ],
            rows: shown, rowKey: (r) => r.event_id, selectedKey: params.event,
            onSelect: (r) => app.setParams({ attempt: r.attempt_no, event: r.event_id }),
            empty: state("", store ? "No blocked items for this pickup store" : "No checkout has been blocked", "", store ? showAllStores : null),
          }),
          rows.length > SHOWN ? h("div", { class: "table-note" },
            h("button", { class: "btn-link", type: "button", onclick: () => { showAll = !showAll; render(); } },
              showAll ? `Show the latest ${SHOWN}` : `Show all ${rows.length}`)) : null),
        foot: rows.length ? `All recorded: ${rows.length} item${rows.length === 1 ? "" : "s"} · ${fmt.units(units)} · ${money.format(value)}.` : null,
      });
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

    loadLists().catch(() => {});
    loadAttempt();
    return {
      update(next) { params = next; render(); loadAttempt(); },
      reload: async () => { await loadLists(); await loadAttempt(true); },
    };
  },
};
