// Demo actions workspace: small forms that call the existing business functions
// (writes to the configured database). Opening the panel changes nothing.

import { get, post } from "../api.js";
import { h, clear, fmt, badge, table, keepFocus, announce, icon } from "./ui.js";

const SECTIONS = [
  ["scenario", "Scenario: stale website stock", "A"],
  ["sale", "Record in-store sale", ""],
  ["supplier_delivery", "Record supplier delivery", ""],
  ["bag", "Online bag and checkout", ""],
  ["sync", "Sync website stock now", "manual"],
  ["mapping", "Add item to product list and run ETL", "C"],
  ["orders", "Order lifecycle", "optional"],
];

export function createDemo(panel, app, { onToggle }) {
  let open = false;
  let cat = null, catErr = null;
  const st = {
    opened: new Set(["scenario"]),
    pending: {},
    results: {},
    sale: { store: "S01", lines: [{ product: "P001", qty: 1 }] },
    supplier_delivery: { location: "NSW-CHATS", supplier: "", order: "", product: "P001", cartons: 5 },
    bag: { postcode: "2026", basket: null, product: "", qty: 1, options: null, pickup: "", loadId: "" },
    scenario: { product: "P018", preview: null },
    mapping: { item: "", reviewing: false },
    orders: { no: "" },
  };

  async function loadCatalogue(force = false) {
    try { cat = await app.catalogue(force); catErr = null; } catch (err) { catErr = err; }
    render();
  }

  function render() { if (open) keepFocus(panel, draw); }

  // ---------- running an action ----------
  async function run(key, fn) {
    if (st.pending[key]) return;
    st.pending[key] = true;
    render();
    let result;
    try {
      result = await fn();
    } catch (err) {
      result = { kind: err.code === "refused" ? "refused" : "error", message: err.message,
        unknown: err.code === "unknown_outcome" };
    }
    if (result.kind !== "error" && result.kind !== "refused" && result.write !== false) {
      const ok = await app.afterWrite();
      if (!ok) result.refreshNote = "Action completed; report refresh failed. Use Refresh to try again.";
      await loadCatalogue(true);
    }
    st.results[key] = result;
    st.pending[key] = false;
    render();
    announce(result.message);
    return result;
  }

  function button(key, label, fn, cls = "btn btn-primary") {
    return h("button", { class: cls, type: "button", "data-fk": `act-${key}`, disabled: st.pending[key] || undefined,
      "aria-busy": st.pending[key] ? "true" : undefined, onclick: () => run(key, fn) },
    st.pending[key] ? "Working…" : label);
  }

  function resultBox(key) {
    const r = st.results[key];
    if (!r) return null;
    return h("div", { class: `result ${r.kind}`, role: "status" },
      h("div", {}, r.title ? h("strong", {}, `${r.title} `) : null, r.message),
      r.unknown ? h("div", { class: "small" }, "Do not repeat the action until you have checked the reports.") : null,
      r.body || null,
      r.refreshNote ? h("div", { class: "small", style: "color:var(--danger)" }, r.refreshNote) : null,
      r.links?.length ? h("div", { class: "links" }, r.links.map(([label, page, params]) =>
        h("button", { class: "btn-link", type: "button", onclick: () => { app.navigate(page, params); maybeCloseOnSmall(); } }, label))) : null);
  }

  function maybeCloseOnSmall() { if (window.matchMedia("(max-width: 860px)").matches) close(); }

  const firstEvent = (staging) => (staging || []).find((s) => s.event_id)?.event_id;
  const traceLink = (staging) => {
    const ev = firstEvent(staging);
    if (ev) return ["View data trace", "integration", { trace_event: ev }];
    const s = (staging || [])[0];
    return s ? ["View data trace", "integration", { trace_table: s.stg_table, trace_id: s.stg_id }] : null;
  };

  function stagingTable(staging) {
    if (!staging?.length) return null;
    return table({
      caption: "Records staged and loaded by this action",
      columns: [
        { label: "Reference", render: (s) => h("span", { class: "mono" }, s.source_ref) },
        { label: "ETL", render: (s) => badge(s.load_status, s.load_status === "loaded" ? "success" : s.load_status === "rejected" ? "danger" : "neutral") },
        { label: "Event", render: (s) => s.event_id ? `${s.event_id} (${s.product_code} ${s.store_code} ${fmt.signed(s.available_change)})` : (s.note || "—") },
      ],
      rows: staging,
    });
  }

  function shelfTable(rows) {
    if (!rows?.length) return null;
    return table({
      caption: "Store system shelf total and website number",
      columns: [
        { label: "Item", render: (r) => r.item_no },
        { label: "Shelf, all stores", render: (r) => fmt.num(r.shelf_total_all_stores) },
        { label: "Website shows", render: (r) => (r.sold_online ? fmt.num(r.website_shown) : "Not sold online") },
      ],
      rows,
    });
  }

  // ---------- options ----------
  const storeOptions = () => cat.stores.map((s) => h("option", { value: s.store_code }, `${s.store_code} · ${s.store_name.replace("PetHaven ", "")} (store ${s.store_no})`));
  const notListed = " (not on warehouse product list)";
  const productOptions = () => cat.store_products.map((p) =>
    h("option", { value: p.item_no }, `${p.item_no} · ${p.description}${p.product_code ? "" : notListed}`));
  const webOptions = () => cat.web_products.map((p) => h("option", { value: p.item_no },
    `${p.item_no} · ${p.title} — website shows ${p.website_shown}`));
  const sel = (fk, value, options, onchange, attrs = {}) => {
    const el = h("select", { "data-fk": fk, ...attrs }, options);
    el.value = value ?? "";
    el.addEventListener("change", () => onchange(el.value));
    return el;
  };
  const num = (fk, value, onchange, label) => h("input", { type: "number", min: "1", max: "999", step: "1", inputmode: "numeric", "data-fk": fk, value: String(value), "aria-label": label,
    oninput: (e) => onchange(e.target.value === "" ? "" : Number(e.target.value)) });
  const lbl = (text, control, hint) => h("label", { class: "field" }, h("span", {}, text), control, hint ? h("small", { class: "hint" }, hint) : null);

  // ---------- sections ----------
  function scenarioSection() {
    const s = st.scenario;
    const online = cat.web_products.filter((p) => p.product_code);
    const p = s.preview;
    const ready = p && p.ready;
    return h("div", { class: "form" },
      h("p", { class: "hint" }, "Shows the business problem end to end with real operations: stores sell a product's last free units, the website still shows it, checkout blocks it, and the sync corrects the website."),
      h("ol", { class: "steps" },
        h("li", {}, lbl("Product sold online", sel("sc-product", s.product, online.map((o) => h("option", { value: o.product_code }, `${o.product_code} · ${o.title}`)), (v) => { s.product = v; s.preview = null; render(); })),
          h("div", { style: "margin-top:8px" }, button("sc-preview", "Preview store stock", async () => {
            const r = await get("/demo/scenarios/sell-out", { product: s.product });
            s.preview = r.data;
            return { kind: "ok", write: false, message: r.data.ready ? `${r.data.units_to_sell} free unit(s) in ${r.data.sales_planned.length} store(s). The website shows ${r.data.website.website_shown}.` : r.data.problem };
          }, "btn")),
          p ? h("div", { style: "margin-top:8px" }, table({
            caption: "Free shelf stock that will be sold",
            columns: [
              { label: "Store", render: (x) => `${x.store_code} · ${x.store_name.replace("PetHaven ", "")}` },
              { label: "Available", render: (x) => fmt.num(x.available) },
              { label: "Reserved (kept)", render: (x) => fmt.num(x.reserved) },
            ],
            rows: p.stores,
          })) : null,
          resultBox("sc-preview")),
        h("li", {}, h("div", {}, "Sell the remaining available units at the till in each store (one receipt per store; reserved units are not touched)."),
          h("div", { style: "margin-top:8px" }, ready ? button("sc-sell", "Sell remaining available units", async () => {
            const r = await post("/demo/scenarios/sell-out", { product: s.product, expected: p.sales_planned.map((x) => ({ store_no: x.store_no, quantity: x.quantity })) });
            s.preview = null;
            return { kind: "ok", message: r.data.message, body: shelfTable(r.data.website_vs_shelf),
              links: [["View website comparison", "website", { product: s.product, status: "different" }]] };
          }) : h("span", { class: "hint" }, "Preview first.")),
          resultBox("sc-sell")),
        h("li", {}, h("div", {}, "A customer in Bondi (postcode 2026) puts 1 unit in a new bag, trusting the website number, and checks out."),
          h("div", { style: "margin-top:8px" }, button("sc-checkout", "Create bag, add 1 unit, check out", async () => {
            const b = await post("/demo/baskets", { postcode: "2026" });
            const id = b.data.basket.basket_id;
            await post(`/demo/baskets/${id}/items`, { product: s.product, quantity: 1 });
            const c = await post(`/demo/baskets/${id}/checkout`, {});
            const blocked = c.data.outcome === "blocked";
            const ev = firstEvent(c.data.staging);
            return { kind: blocked ? "blocked" : "ok", title: `Bag ${id}, attempt ${c.data.attempt_no}:`, message: c.data.message,
              links: [["View blocked item", "checkout", { attempt: c.data.attempt_no, event: ev || "" }], ev ? ["View data trace", "integration", { trace_event: ev }] : null].filter(Boolean) };
          }, "btn")),
          resultBox("sc-checkout")),
        h("li", {}, h("div", {}, "Run the website sync: the website takes the real shelf totals from the store system."),
          h("div", { style: "margin-top:8px" }, button("sc-sync", "Sync website stock", () => doSync("sc-sync", s.product), "btn")),
          resultBox("sc-sync")),
        h("li", {}, h("div", {}, "A new customer tries to add 1 unit. The product page now refuses it (this is not another blocked checkout)."),
          h("div", { style: "margin-top:8px" }, button("sc-add", "Try adding 1 unit to a new bag", async () => {
            const b = await post("/demo/baskets", { postcode: "2026" });
            const id = b.data.basket.basket_id;
            try {
              await post(`/demo/baskets/${id}/items`, { product: s.product, quantity: 1 });
              return { kind: "ok", message: `Bag ${id}: the item was added — the website still shows stock for it.` };
            } catch (err) {
              if (err.code !== "refused") throw err;
              return { kind: "refused", title: `Bag ${id}:`, message: `Refused as expected — ${err.message}.` };
            }
          }, "btn")),
          resultBox("sc-add"))));
  }

  async function doSync(key, highlight) {
    const r = await post("/demo/sync", {});
    const d = r.data;
    return {
      kind: "ok", title: `Manual sync ${d.source_sync_no} → warehouse sync ${d.warehouse_sync?.sync_id ?? "?"}:`, message: d.message,
      body: d.website_changes.length ? table({
        caption: "Website quantities changed by this sync",
        columns: [
          { label: "Item", render: (c) => (c.item_no === highlight ? h("b", {}, c.item_no) : c.item_no) },
          { label: "Before", render: (c) => fmt.num(c.before_qty) },
          { label: "After", render: (c) => fmt.num(c.after_qty) },
          { label: "Change", render: (c) => fmt.signed(c.change) },
        ],
        rows: d.website_changes,
      }) : null,
      links: [["View latest website sync", "website", {}]],
    };
  }

  function saleSection() {
    const s = st.sale;
    return h("div", { class: "form" },
      lbl("Store", sel("sale-store", s.store, storeOptions(), (v) => { s.store = v; })),
      s.lines.map((line, i) => h("div", { class: "row2" },
        lbl(i ? `Item ${i + 1}` : "Item", sel(`sale-p${i}`, line.product, productOptions(), (v) => { line.product = v; })),
        lbl("Units", num(`sale-q${i}`, line.qty, (v) => { line.qty = v; }, `Units of product ${i + 1}`)),
        s.lines.length > 1 ? h("button", { class: "btn", type: "button", "aria-label": `Remove product ${i + 1}`, onclick: () => { s.lines.splice(i, 1); render(); } }, icon("close")) : h("span"))),
      h("div", {}, h("button", { class: "btn btn-small", type: "button", onclick: () => { s.lines.push({ product: "P005", qty: 1 }); render(); } }, "Add another product")),
      h("div", {}, button("sale", "Record sale", async () => {
        const r = await post("/demo/sales", { store: s.store, items: s.lines.map((l) => ({ product: l.product, quantity: l.qty })) });
        const d = r.data;
        const firstProduct = d.staging.find((x) => x.product_code)?.product_code;
        return { kind: "ok", title: `Receipt number ${d.sale_no}:`, message: d.message,
          body: [stagingTable(d.staging), shelfTable(d.website_vs_shelf)],
          links: [firstProduct ? ["View affected report", "inventory", { product: firstProduct, store_sel: s.store }] : ["View rejected records", "integration", {}], traceLink(d.staging)].filter(Boolean) };
      })),
      resultBox("sale"));
  }

  function supplierDeliverySection() {
    const s = st.supplier_delivery;
    return h("div", { class: "form" },
      lbl("Supplier delivery location", sel("del-loc", s.location, cat.locations.map((l) => h("option", { value: l.location_code }, `${l.location_code} · ${l.location_name.replace(" (store receiving dock)", "")}`)), (v) => { s.location = v; })),
      h("div", { class: "row2", style: "grid-template-columns:minmax(0,1fr) 90px" },
        lbl("Item", sel("del-item", s.product, cat.supplier_items.map((i) => h("option", { value: i.item_no },
          `${i.item_no} · ${i.item_description} · ${i.units_per_carton}/carton · ${i.supplier_id}${i.product_code ? "" : notListed}`)), (v) => { s.product = v; })),
        lbl("Cartons", num("del-cartons", s.cartons, (v) => { s.cartons = v; }, "Cartons"))),
      h("div", { class: "row2", style: "grid-template-columns:minmax(0,1fr) minmax(0,1fr)" },
        lbl("Supplier ID", sel("del-sup", s.supplier, [h("option", { value: "" }, "The item's supplier"),
          ...cat.suppliers.map((x) => h("option", { value: x.supplier_id }, `${x.supplier_id} · ${x.supplier_name}`))], (v) => { s.supplier = v; })),
        lbl("Supplier order number", h("input", { type: "text", "data-fk": "del-order", value: s.order, maxlength: "30", placeholder: "Numbered automatically",
          oninput: (e) => { s.order = e.target.value.trim(); } }))),
      h("p", { class: "hint" }, "Quantities are in cartons and the supplier delivery time is recorded in UTC, as the supplier delivery system does. The ETL converts both. The supplier ID and supplier order number identify the delivery in the warehouse."),
      h("div", {}, button("supplier_delivery", "Record supplier delivery", async () => {
        const body = { location: s.location, items: [{ product: s.product, cartons: s.cartons }] };
        if (s.supplier) body.supplier_id = s.supplier;
        if (s.order) body.supplier_order_no = s.order;
        const r = await post("/demo/supplier-deliveries", body);
        s.order = "";
        const d = r.data;
        const l = d.lines[0];
        const st0 = d.staging[0];
        return { kind: "ok", title: `Supplier ${d.supplier_id}, order ${d.supplier_order_no}:`, message: d.message,
          body: [h("div", {}, `${l.cartons} cartons × ${l.units_per_carton} units/carton = ${l.units} units. Recorded at UTC ${l.delivered_at_utc} (Sydney ${fmt.dateTimeSec(l.delivered_at_sydney)}).`),
            stagingTable(d.staging), shelfTable(d.website_vs_shelf)],
          links: [st0?.product_code ? ["View affected report", "inventory", { product: st0.product_code, store_sel: st0.store_code }] : ["View rejected records", "integration", {}], traceLink(d.staging)].filter(Boolean) };
      })),
      resultBox("supplier_delivery"));
  }

  function bagSection() {
    const s = st.bag;
    const b = s.basket;
    const parts = [
      h("div", { class: "row2", style: "grid-template-columns:minmax(0,1fr) auto" },
        lbl("Customer postcode", sel("bag-postcode", s.postcode, cat.postcodes.map((p) => h("option", { value: p.postcode }, `${p.postcode} · ${p.suburb}`)), (v) => { s.postcode = v; })),
        button("bag-create", "Create bag", async () => {
          const r = await post("/demo/baskets", { postcode: s.postcode });
          s.basket = r.data.basket; s.options = null; s.pickup = "";
          return { kind: "ok", message: r.data.message, write: false };
        }, "btn")),
      h("div", { class: "row2", style: "grid-template-columns:minmax(0,1fr) auto" },
        lbl("Or open an existing bag", h("input", { type: "text", inputmode: "numeric", "data-fk": "bag-load", value: s.loadId, placeholder: "Bag number", oninput: (e) => { s.loadId = e.target.value.trim(); } })),
        button("bag-open", "Open", async () => {
          if (!/^\d+$/.test(s.loadId)) return { kind: "refused", message: "Enter a bag number." };
          const r = await get(`/demo/baskets/${s.loadId}`);
          s.basket = r.data; s.options = null; s.pickup = "";
          return { kind: "ok", write: false, message: `Bag ${r.data.basket_id} opened (${r.data.status}).` };
        }, "btn")),
      resultBox("bag-create"), resultBox("bag-open"),
    ];
    if (b) {
      const openBag = b.status === "open";
      parts.push(h("div", { class: "bag" },
        h("div", {}, h("strong", {}, `Bag ${b.basket_id}`), ` · ${b.customer_postcode} ${b.suburb} · `, badge(openBag ? "Open" : "Checked out", openBag ? "info" : "success")),
        b.items.length ? h("ul", {}, b.items.map((i) => h("li", {},
          h("span", {}, `${i.quantity} × ${i.item_no} ${i.title}`, h("span", { class: "cell-sub" }, `website showed ${i.website_qty_at_add} when added; shows ${i.website_shown_now} now`)),
          openBag ? h("button", { class: "btn btn-small", type: "button", "data-fk": `rm-${i.item_no}`, disabled: st.pending.bag || undefined,
            onclick: () => run("bag", async () => {
              const r = await post(`/demo/baskets/${b.basket_id}/remove-item`, { product: i.item_no });
              s.basket = r.data.basket; s.options = null;
              return { kind: "ok", write: false, message: r.data.message };
            }) }, "Remove") : null))) : h("p", { class: "hint" }, "The bag is empty."),
        b.attempts.length ? h("p", { class: "hint", style: "margin-top:6px" }, "Checkout attempts: ", b.attempts.map((a, n) => `${n ? ", " : ""}#${a.attempt_no} ${a.outcome}${a.order_no ? ` (order ID ${a.order_no})` : ""}`).join("")) : null));
      if (openBag) {
        parts.push(
          h("div", { class: "row2" },
            lbl("Item", sel("bag-product", s.product, webOptions(), (v) => { s.product = v; })),
            lbl("Units", num("bag-qty", s.qty, (v) => { s.qty = v; }, "Units in bag")),
            button("bag", "Set quantity in bag", async () => {
              const r = await post(`/demo/baskets/${b.basket_id}/items`, { product: s.product || cat.web_products[0].item_no, quantity: s.qty });
              s.basket = r.data.basket; s.options = null;
              return { kind: "ok", write: false, message: r.data.message };
            }, "btn")),
          h("p", { class: "hint" }, "Sets the quantity of that product in the bag (it does not add to it). Allowed only up to the website number; nothing is held."),
          resultBox("bag"),
          b.items.length ? h("div", {}, button("bag-options", "Show pickup options", async () => {
            const r = await get(`/demo/baskets/${b.basket_id}/pickup-options`);
            s.options = r.data.options; s.pickup = "";
            return { kind: "ok", write: false, message: r.data.options.length ? `${r.data.options.length} pickup option(s): stores holding at least one bag item.` : "No store holds any bag item; checkout would be blocked." };
          }, "btn")) : null,
          resultBox("bag-options"));
        if (s.options) {
          parts.push(h("fieldset", { class: "options", style: "border:0;padding:0;margin:0" },
            h("legend", { class: "hint", style: "margin-bottom:6px" }, "Pickup store"),
            h("label", {}, h("input", { type: "radio", name: "pickup", value: "", checked: !s.pickup, "data-fk": "pk-auto", onchange: () => { s.pickup = ""; } }),
              h("span", {}, h("b", {}, "Automatic"), h("span", { class: "cell-sub" }, "Top option: fewest transfers, then nearest"))),
            s.options.map((o) => h("label", {},
              h("input", { type: "radio", name: "pickup", value: o.cp_code, checked: s.pickup === o.cp_code, "data-fk": `pk-${o.cp_code}`, onchange: () => { s.pickup = o.cp_code; } }),
              h("span", {}, h("b", {}, `${o.option_rank}. ${o.cp_name.replace("Click & Collect - ", "")}`),
                h("span", { class: "cell-sub" }, `${o.distance_km} km · ${o.items_here} item(s) here, ${o.items_transferred} transferred${o.items_unavailable ? `, ${o.items_unavailable} unavailable in any single store` : ""}`))))));
        }
        if (b.items.length) {
          parts.push(h("div", {}, button("checkout", "Check out", async () => {
            const r = await post(`/demo/baskets/${b.basket_id}/checkout`, s.pickup ? { pickup: s.pickup } : {});
            const d = r.data;
            s.basket = d.basket; s.options = null;
            const ev = firstEvent(d.staging);
            return { kind: d.outcome === "blocked" ? "blocked" : "ok", title: `Attempt ${d.attempt_no}:`, message: d.message,
              body: d.outcome === "blocked" ? h("div", {}, "Unavailable: ", d.unavailable_items.map((i) => `${i.quantity} × ${i.item_no} (website showed ${i.website_qty_shown})`).join(", "), ". Remove them and check out again.") : null,
              links: d.outcome === "blocked"
                ? [["View blocked item", "checkout", { attempt: d.attempt_no, event: ev || "" }], ev ? ["View data trace", "integration", { trace_event: ev }] : null].filter(Boolean)
                : [["View open reservations", "checkout", { tab: "reservations" }], ["View website comparison", "website", {}]] };
          })), resultBox("checkout"));
        }
      }
    }
    return h("div", { class: "form" }, parts);
  }

  function syncSection() {
    return h("div", { class: "form" },
      h("p", { class: "hint" }, "The online store reads the real shelf totals from the store system and replaces its website numbers. While the scheduler runs, this happens automatically at the interval shown on Website stock; this button runs it now, as a manual sync. The warehouse records the before and after values for reporting; it does not set them. Refresh reports never runs this."),
      h("div", {}, button("sync", "Sync website stock now", () => doSync("sync"))),
      resultBox("sync"));
  }

  function mappingSection() {
    const s = st.mapping;
    const unlisted = cat.store_products.filter((p) => !p.product_code);
    if (!unlisted.find((u) => u.item_no === s.item)) s.item = unlisted[0]?.item_no || "";
    const chosen = unlisted.find((u) => u.item_no === s.item);
    const etl = h("div", { class: "form", style: "border-top:1px dashed var(--border);margin-top:4px;padding-top:12px" },
      h("p", { class: "hint" }, "Adding an item does not load anything by itself. Run the ETL to retry the waiting records."),
      h("div", {}, button("etl", "Run ETL", async () => {
        const r = await post("/demo/etl", {});
        const d = r.data;
        return { kind: "ok", title: d.etl_run_id ? `Run ${d.etl_run_id}:` : "", message: d.message,
          body: d.handled?.length ? table({ caption: "Records handled by this run", columns: [
            { label: "Reference", render: (x) => h("span", { class: "mono" }, x.source_ref) },
            { label: "Result", render: (x) => badge(x.load_status, x.load_status === "loaded" ? "success" : x.load_status === "rejected" ? "danger" : "neutral") },
            { label: "Event", render: (x) => x.event_id || x.note || "—" }], rows: d.handled }) : null,
          links: [["View integration and quality", "integration", {}], d.handled?.[0]?.event_id ? ["View data trace", "integration", { trace_event: d.handled[0].event_id }] : null].filter(Boolean) };
      }, "btn")),
      resultBox("etl"));
    if (!unlisted.length) {
      return h("div", { class: "form" },
        h("div", { class: "result" }, h("strong", {}, "Already prepared or completed."),
          "Every item in the store catalogue is on the warehouse product list, so there is nothing to add. For a fresh rejection demonstration, rebuild the database manually with scripts/build.py (see the dashboard runbook). Items are never removed from the list automatically."),
        resultBox("mapping"), etl);
    }
    return h("div", { class: "form" },
      h("p", { class: "hint" }, "Data-steward step. Every system uses the same item number, but the warehouse only accepts items on its product list. Records for any other item are rejected as \u201cUnknown item\u201d — never guessed — until the item is added."),
      lbl("Item not on the warehouse product list", sel("map-code", s.item, unlisted.map((u) => h("option", { value: u.item_no }, `${u.item_no} · ${u.description}`)),
        (v) => { s.item = v; s.reviewing = false; render(); })),
      !s.reviewing
        ? h("div", {}, h("button", { class: "btn", type: "button", "data-fk": "map-review", onclick: () => {
            s.reviewing = true; delete st.results.mapping; render();
            panel.querySelector('[data-fk="act-mapping"]')?.focus();
          } }, "Review"))
        : h("div", { class: "result refused" },
            h("strong", {}, "Review before adding"),
            h("div", {}, `Add item ${s.item} (\u201c${chosen?.description}\u201d) to the warehouse product list. From now on the ETL loads every record for ${s.item}.`),
            h("div", { class: "links" },
              button("mapping", "Add to product list", async () => {
                const r = await post("/demo/items/add", { item_no: s.item });
                s.reviewing = false;
                return { kind: "ok", message: r.data.message, links: [["View item list", "integration", { tab: "mappings" }]] };
              }),
              h("button", { class: "btn", type: "button", onclick: () => { s.reviewing = false; render(); } }, "Cancel"))),
      resultBox("mapping"), etl);
  }

  function ordersSection() {
    const s = st.orders;
    const step = (name, label) => button(`order-${name}`, label, async () => {
      if (!/^\d+$/.test(s.no)) return { kind: "refused", message: "Enter an order ID from the open reservations report." };
      const r = await post(`/demo/orders/${s.no}/${name}`, name === "cancel" ? { reason: "Customer cancelled" } : {});
      return { kind: "ok", message: r.data.message, links: [["View open reservations", "checkout", { tab: "reservations" }]] };
    }, "btn btn-small");
    return h("div", { class: "form" },
      h("p", { class: "hint" }, "Optional. Take order IDs from Orders & lost sales → Click & collect orders. Refused steps (for example collecting before transfers arrive) show the store system's reason."),
      lbl("Order ID", h("input", { type: "text", inputmode: "numeric", "data-fk": "order-no", value: s.no, oninput: (e) => { s.no = e.target.value.trim(); } })),
      h("div", { class: "links", style: "display:flex;gap:8px;flex-wrap:wrap" },
        step("dispatch", "Send transfers"), step("receive", "Receive transfers"), step("collect", "Customer collects"), step("cancel", "Cancel order")),
      ["dispatch", "receive", "collect", "cancel"].map((n) => resultBox(`order-${n}`)),
      h("div", {}, button("overdue", "Cancel overdue orders (3 days)", async () => {
        const r = await post("/demo/cancel-overdue", {});
        return { kind: "ok", message: r.data.message, links: [["View open reservations", "checkout", { tab: "reservations" }]] };
      }, "btn btn-small")),
      resultBox("overdue"));
  }

  const BUILDERS = { scenario: scenarioSection, sale: saleSection, supplier_delivery: supplierDeliverySection, bag: bagSection, sync: syncSection, mapping: mappingSection, orders: ordersSection };

  function draw() {
    clear(panel);
    panel.append(h("div", { class: "demo-head" },
      h("div", { class: "row" },
        h("h2", { id: "demo-title", tabindex: "-1" }, "Demo actions"),
        h("button", { class: "btn btn-small", type: "button", onclick: close }, h("span", { class: "btn-label-long" }, "Close"), h("span", { class: "sr-only" }, " Demo actions panel"), " ×")),
      h("p", { class: "warn-line" }, h("strong", {}, "Writes to the database. "), "Each action records real business events in the source systems. Opening this panel changes nothing.")));
    const body = h("div", { class: "demo-body" });
    if (catErr) body.append(h("div", { class: "result error", role: "alert" }, catErr.message, h("button", { class: "btn btn-small", type: "button", onclick: () => loadCatalogue(true) }, "Retry")));
    else if (!cat) body.append(h("p", { class: "hint", style: "padding:16px 0" }, "Loading catalogue…"));
    else {
      for (const [key, title, tag] of SECTIONS) {
        const det = h("details", { open: st.opened.has(key) || undefined, "data-section": key },
          h("summary", { "data-fk": `sum-${key}` }, title, tag ? h("small", {}, tag) : null),
          st.opened.has(key) ? BUILDERS[key]() : null);
        det.addEventListener("toggle", () => {
          if (det.open === st.opened.has(key)) return;
          det.open ? st.opened.add(key) : st.opened.delete(key);
          render();
        });
        body.append(det);
      }
    }
    panel.append(body);
  }

  function close() {
    if (!open) return;
    open = false;
    panel.hidden = true;
    onToggle(false);
  }

  panel.addEventListener("keydown", (e) => { if (e.key === "Escape") { e.stopPropagation(); close(); } });

  return {
    isOpen: () => open,
    open(section, prefill) {
      if (section) st.opened.add(section);
      if (section === "mapping" && prefill) {
        st.mapping.item = prefill.item_no; st.mapping.reviewing = false;
      }
      const wasOpen = open;
      open = true;
      panel.hidden = false;
      onToggle(true);
      render();
      if (!cat) loadCatalogue();
      if (!wasOpen || section) {
        requestAnimationFrame(() => {
          const target = section ? panel.querySelector(`[data-section="${section}"] summary`) : panel.querySelector("#demo-title");
          target?.focus();
          target?.scrollIntoView({ block: "nearest" });
        });
      }
    },
    close,
  };
}
