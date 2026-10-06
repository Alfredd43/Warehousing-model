// Page D: Integration & Quality — architecture, trace, mappings, ETL runs, staging, reconciliation.

import { get } from "../api.js";
import { h, clear, fmt, badge, card, state, loading, field, select, table, pager, tabs, kv, errorState, keepFocus, icon } from "../components/ui.js";

const STATUS_KIND = { loaded: "success", rejected: "danger", skipped: "neutral", pending: "warning" };
const TABLE_LABEL = {
  stg_store_sale_line: "Store sale line", stg_supplier_delivery_line: "Supplier delivery line",
  stg_reservation_change: "Reservation step", stg_checkout_item: "Checkout item",
};

export default {
  mount(root, app, initialParams) {
    let params = initialParams;
    const data = {};      // name -> response
    const errors = {};    // name -> error
    const keys = {};      // name -> last query key
    const tokens = {};

    async function load(name, path, query = {}, force = false) {
      const key = JSON.stringify(query);
      if (!force && keys[name] === key && (data[name] || errors[name])) return;
      keys[name] = key;
      const my = (tokens[name] = (tokens[name] || 0) + 1);
      delete errors[name];
      data[name] = null;
      render();
      try {
        const r = await get(path, query);
        if (my !== tokens[name]) return;
        data[name] = r;
        app.markRead(r.meta);
      } catch (err) {
        if (my !== tokens[name]) return;
        errors[name] = err;
      }
      render();
      if (errors[name]) throw errors[name];
    }

    function tab() { return ["mappings", "staging", "sync"].includes(params.tab) ? params.tab : "overview"; }

    function traceQuery() {
      if (params.trace_event) return { event_id: params.trace_event };
      if (params.trace_table && params.trace_id) return { table: params.trace_table, id: params.trace_id };
      return null;
    }

    function needed(force = false) {
      const jobs = [];
      const tq = traceQuery();
      if (tq) jobs.push(load("trace", "/integration/trace", tq, force));
      else { data.trace = null; keys.trace = null; delete errors.trace; }
      const t = tab();
      if (t === "overview") {
        jobs.push(load("quality", "/integration/quality", {}, force));
        jobs.push(load("latestRun", "/integration/runs", { limit: 1 }, force));
      } else if (t === "mappings") {
        jobs.push(load("mappings", "/integration/mappings", {}, force));
      } else if (t === "staging") {
        jobs.push(load("runs", "/integration/runs", { limit: 10, offset: params.runoff }, force));
        jobs.push(load("staging", "/integration/staging", { source: params.stsrc, status: params.ststat, limit: 25, offset: params.stoff }, force));
      } else {
        jobs.push(load("sync", "/integration/sync-staging", { status: params.systat, limit: 25, offset: params.syoff }, force));
      }
      return Promise.allSettled(jobs).then((r) => { const bad = r.find((x) => x.status === "rejected"); if (bad) throw bad.reason; });
    }

    function render() { keepFocus(root, draw); }

    function block(name, build) {
      if (errors[name]) return errorState(errors[name], () => needed(true).catch(() => {}));
      if (!data[name]) return loading();
      return build(data[name]);
    }

    function draw() {
      clear(root);
      root.append(h("div", { class: "page-head" },
        h("div", {},
          h("h1", {}, "Integration & Quality"),
          h("p", { class: "subtitle" }, "Trace source records through ETL and verify warehouse completeness."),
          h("span", { class: "report-id" }, "Solution evidence · three sources → staging → warehouse"))));
      if (traceQuery()) root.append(traceCard());
      root.append(tabs([
        { value: "overview", label: "Overview and quality" },
        { value: "mappings", label: "Code mappings" },
        { value: "staging", label: "ETL runs and staging" },
        { value: "sync", label: "Website sync records" },
      ], tab(), (v) => app.setParams({ tab: v === "overview" ? "" : v }), "Integration views"));
      const t = tab();
      if (t === "overview") drawOverview();
      else if (t === "mappings") drawMappings();
      else if (t === "staging") drawStaging();
      else drawSync();
    }

    // ---------- overview ----------
    function architecture() {
      const arrow = () => h("div", { class: "flow-arrow", "aria-hidden": "true" }, icon("arrow"));
      return card({
        id: "architecture", title: "How data reaches the reports",
        body: h("div", { class: "card-body" },
          h("div", { class: "flow", role: "img", "aria-label": "Store operations, supplier deliveries and the online store feed staging; staging is mapped, converted and validated; valid rows load into the warehouse; reports read the warehouse." },
            h("div", { class: "flow-sources" },
              h("div", { class: "flow-node" }, "Store operations"),
              h("div", { class: "flow-node" }, "Supplier deliveries"),
              h("div", { class: "flow-node" }, "Online store")),
            arrow(), h("div", { class: "flow-node" }, "Staging"),
            arrow(), h("div", { class: "flow-node" }, "Map / convert / validate"),
            arrow(), h("div", { class: "flow-node dw" }, "Warehouse"),
            arrow(), h("div", { class: "flow-node" }, "Reports")),
          h("p", { class: "secondary small", style: "margin-top:12px" },
            "Website sync copies available quantities from the store system to the online system; its log is recorded in the warehouse.")),
      });
    }

    function drawOverview() {
      root.append(h("div", { class: "stack" },
        architecture(),
        card({ id: "reconciliation", title: "Reconciliation: store system vs warehouse",
          subtitle: "Live store balances (source) compared with balances rebuilt from warehouse events, per store and product.",
          body: block("quality", (r) => {
            const s = r.data.summary;
            const head = h("div", { class: "card-body", style: "padding-bottom:8px" },
              s.compared_pairs === 0
                ? h("div", { class: "banner error" }, "No comparison rows: reconciliation is unavailable, not successful.")
                : h("p", { class: "lede", style: "margin:0" }, h("b", {}, `${s.matching_pairs} of ${s.compared_pairs}`), " compared store-product pairs match.",
                    s.mismatched_pairs ? " " : h("span", { class: "secondary" }, " Scope: every row in the store system's stock table.")));
            return h("div", {}, head, r.data.mismatches.length ? table({
              caption: "Store-product pairs where the warehouse differs from the store system",
              columns: [
                { label: "Store source code", key: "store_no" },
                { label: "Product source code", render: (m) => h("span", { class: "mono" }, m.barcode) },
                { label: "Unified store / product", render: (m) => `${m.store_code ?? "Not mapped"} / ${m.product_code ?? "Not mapped"}` },
                { label: "Source available", num: true, render: (m) => fmt.num(m.source_in_store) },
                { label: "Warehouse available", num: true, render: (m) => (m.warehouse_in_store === null ? "No warehouse row" : fmt.num(m.warehouse_in_store)) },
                { label: "Source reserved", num: true, render: (m) => fmt.num(m.source_reserved) },
                { label: "Warehouse reserved", num: true, render: (m) => (m.warehouse_reserved === null ? "No warehouse row" : fmt.num(m.warehouse_reserved)) },
                { label: "Status", render: (m) => h("span", { class: "badge b-warning wrap" }, m.status) },
              ],
              rows: r.data.mismatches,
            }) : null);
          }) }),
        card({ id: "rejected", title: "Rejected source records",
          subtitle: "Business-event records the ETL could not load. They stay in staging and are retried on every ETL pass.",
          body: block("quality", (r) => r.data.rejected.length ? table({
            caption: "Source records currently rejected by the ETL",
            columns: [
              { label: "Source", render: (q) => q.source_system },
              { label: "Reference", render: (q) => h("span", { class: "mono" }, q.source_ref) },
              { label: "Reason", key: "reject_reason" },
              { label: "Captured", render: (q) => fmt.dateTime(q.captured_at) },
              { label: "Last attempt", render: (q) => fmt.dateTime(q.last_attempt_at) },
              { label: "Actions", render: (q) => h("span", {},
                  h("a", { href: `#/integration?trace_table=${q.stg_table}&trace_id=${q.stg_id}` }, "Trace"),
                  mappingCode(q) ? [" · ", h("button", { class: "btn-link", type: "button",
                    onclick: () => app.openDemo("mapping", { source_system: q.source_system, source_code: mappingCode(q) }) }, "Review mapping")] : null) },
            ],
            rows: r.data.rejected,
          }) : state("", "No currently rejected business-event records", "Website sync lines are checked separately (see Website sync records).")) }),
        card({ id: "latest-run", title: "Latest ETL run",
          body: block("latestRun", (r) => {
            const run = r.data.rows[0];
            if (!run) return state("", "No ETL run recorded", "");
            return h("div", { class: "card-body" }, kv([
              ["Run", `${run.etl_run_id} · ${run.trigger_source}`],
              ["Finished", fmt.dateTimeSec(run.finished_at)],
              ["Rows handled", `${run.rows_read} read · ${run.rows_loaded} loaded · ${run.rows_rejected} rejected · ${run.rows_skipped} skipped`],
            ]), h("p", { class: "secondary small", style: "margin-top:10px" },
              "The ETL runs inside each source transaction (change-data-capture triggers), so there is no background job to watch. ",
              h("a", { href: "#/integration?tab=staging" }, "All runs and staged records")));
          }) })));
    }

    function mappingCode(q) {
      const m = /^No approved (STORE|SUPPLY|ONLINE) product mapping for code (.+)$/.exec(q.reject_reason || "");
      return m ? m[2] : null;
    }

    // ---------- mappings ----------
    function drawMappings() {
      root.append(block("mappings", (r) => h("div", { class: "stack" },
        card({ id: "product-codes", title: "Product codes in each system",
          subtitle: "Approved mappings from each source's own code to the warehouse product code. Names are never used to match.",
          body: table({
            caption: "Product code mappings",
            columns: [
              { label: "Warehouse product", key: "product_code" },
              { label: "Product name", key: "product_name" },
              { label: "Store barcode", render: (p) => (p.store_barcode ? h("span", { class: "mono" }, p.store_barcode) : badge("Not mapped", "warning")) },
              { label: "Supplier SKU", render: (p) => (p.supplier_sku ? h("span", { class: "mono" }, p.supplier_sku) : badge("Not mapped", "warning")) },
              { label: "Web SKU", render: (p) => (p.web_sku ? h("span", { class: "mono" }, p.web_sku) : p.in_web_catalogue ? badge("Not mapped", "warning") : badge("Not sold online", "neutral", { dot: false })) },
            ],
            rows: r.data.products,
          }) }),
        card({ id: "store-codes", title: "Store codes in each system",
          body: table({
            caption: "Store code mappings",
            columns: [
              { label: "Warehouse store", key: "store_code" },
              { label: "Store name", key: "store_name" },
              { label: "Store code", render: (s) => s.store_no ?? badge("Not mapped", "warning") },
              { label: "Supplier delivery location", render: (s) => s.location_code ?? badge("Not mapped", "warning") },
              { label: "Collection point", render: (s) => s.cp_code ?? badge("Not mapped", "warning") },
            ],
            rows: r.data.stores,
          }) }),
        card({ id: "unmapped", title: "Source products without an approved mapping",
          subtitle: "These codes exist in a source catalogue but not in the warehouse. Their records are rejected with a reason until a data steward approves a mapping.",
          body: r.data.unmapped_source_products.length ? table({
            caption: "Unmapped source product codes",
            columns: [
              { label: "Source", key: "source_system" },
              { label: "Source code", render: (u) => h("span", { class: "mono" }, u.source_code) },
              { label: "Name in that source", key: "source_name" },
              { label: "Action", render: (u) => h("button", { class: "btn btn-small btn-accent", type: "button",
                  onclick: () => app.openDemo("mapping", { source_system: u.source_system, source_code: u.source_code }) }, "Review mapping") },
            ],
            rows: r.data.unmapped_source_products,
          }) : state("", "Every source product code has an approved mapping", "") }))));
    }

    // ---------- staging and runs ----------
    function drawStaging() {
      root.append(h("div", { class: "stack" },
        card({ id: "etl-runs", title: "ETL runs",
          subtitle: "Recorded results of completed passes. A rejected row is retried on every pass, so do not add rejected counts across runs.",
          body: block("runs", (r) => h("div", {}, table({
            caption: "ETL run log",
            columns: [
              { label: "Run ID", key: "etl_run_id" },
              { label: "Trigger", render: (x) => h("span", { class: "mono" }, x.trigger_source) },
              { label: "Started", render: (x) => fmt.dateTimeSec(x.started_at) },
              { label: "Finished", render: (x) => fmt.dateTimeSec(x.finished_at) },
              { label: "Read", num: true, key: "rows_read" },
              { label: "Loaded", num: true, key: "rows_loaded" },
              { label: "Rejected", num: true, key: "rows_rejected" },
              { label: "Skipped", num: true, key: "rows_skipped" },
            ],
            rows: r.data.rows, empty: state("", "No ETL run recorded", ""),
          }), pager(r.data, (off) => app.setParams({ runoff: off ? String(off) : "" })))) }),
        card({ id: "staging", title: "Staged business-event records",
          subtitle: "Every extracted sale line, supplier delivery line, reservation step and checkout item, and what the ETL did with it. Select a row to trace it.",
          actions: [
            field("Source", select([{ value: "", label: "All sources" }, { value: "STORE", label: "Store system" }, { value: "SUPPLY", label: "Supplier delivery system" }, { value: "ONLINE", label: "Online store" }],
              params.stsrc || "", (v) => app.setParams({ stsrc: v, stoff: "" }), { "data-fk": "stsrc" })),
            field("Status", select([{ value: "", label: "All statuses" }, ...["loaded", "rejected", "skipped", "pending"].map((s) => ({ value: s, label: s[0].toUpperCase() + s.slice(1) }))],
              params.ststat || "", (v) => app.setParams({ ststat: v, stoff: "" }), { "data-fk": "ststat" })),
          ],
          body: block("staging", (r) => h("div", {},
            h("div", { class: "card-body", style: "padding-top:4px;padding-bottom:8px" }, h("p", { class: "small secondary" },
              "All staged rows: ", r.data.status_counts.map((c, n) => [n ? " · " : "", `${c.n} ${c.load_status}`]),
              ". Skipped is not a failure: an available checkout item's stock movement is loaded from the store reservation instead.")),
            table({
              caption: "Staged business-event records",
              columns: [
                { label: "Source", render: (x) => x.source_system, sub: (x) => TABLE_LABEL[x.stg_table] },
                { label: "Reference", render: (x) => h("span", { class: "mono" }, x.source_ref) },
                { label: "Status", render: (x) => badge(x.load_status, STATUS_KIND[x.load_status] || "neutral") },
                { label: "Note", render: (x) => x.note || "" },
                { label: "ETL run", num: true, render: (x) => x.etl_run_id ?? "—" },
                { label: "Event ID", num: true, render: (x) => x.event_id ?? "—" },
                { label: "Captured at", render: (x) => fmt.dateTimeSec(x.captured_at) },
              ],
              rows: r.data.rows, rowKey: (x) => `${x.stg_table}:${x.stg_id}`,
              selectedKey: params.trace_table ? `${params.trace_table}:${params.trace_id}` : undefined,
              onSelect: (x) => app.setParams({ trace_table: x.stg_table, trace_id: x.stg_id, trace_event: "" }),
              empty: state("", "No staged records match these filters", ""),
            }), pager(r.data, (off) => app.setParams({ stoff: off ? String(off) : "" })))) })));
    }

    // ---------- website sync records ----------
    function drawSync() {
      root.append(card({ id: "sync-records", title: "Website sync records",
        subtitle: "The online store's sync log, extracted line by line. This stream is not part of the business-event staging or the rejected-records list, and has no ETL run ID; it links to the warehouse sync instead.",
        actions: field("Status", select([{ value: "", label: "All statuses" }, { value: "loaded", label: "Loaded" }, { value: "skipped", label: "Skipped" }, { value: "pending", label: "Pending" }],
          params.systat || "", (v) => app.setParams({ systat: v, syoff: "" }), { "data-fk": "systat" })),
        body: block("sync", (r) => h("div", {}, table({
          caption: "Website sync log lines and their warehouse sync",
          columns: [
            { label: "Online sync", num: true, key: "source_sync_no" },
            { label: "Warehouse sync", num: true, render: (x) => x.warehouse_sync_id ?? "Not recorded" },
            { label: "Web SKU", render: (x) => h("span", { class: "mono" }, x.web_sku) },
            { label: "Before", num: true, key: "before_qty" },
            { label: "After", num: true, key: "after_qty" },
            { label: "Status", render: (x) => badge(x.load_status, STATUS_KIND[x.load_status] || "neutral") },
            { label: "Note", render: (x) => x.note || "" },
            { label: "Captured at", render: (x) => fmt.dateTimeSec(x.captured_at) },
          ],
          rows: r.data.rows, empty: state("", "No website sync records", "No website sync has been recorded."),
        }), pager(r.data, (off) => app.setParams({ syoff: off ? String(off) : "" })))) }));
    }

    // ---------- trace ----------
    function traceCard() {
      const close = h("button", { class: "btn btn-small", type: "button", onclick: () => app.setParams({ trace_event: "", trace_table: "", trace_id: "" }) }, "Close trace");
      return card({ id: "trace", title: "Data trace", subtitle: "One source record followed through staging and transformation into the warehouse.",
        actions: close,
        body: block("trace", (r) => {
          const d = r.data;
          const s = d.staging;
          const t = d.transform;
          const w = d.warehouse;
          const rec = d.source.record;
          const step = (n, title, ...content) => h("div", { class: "trace-step" }, h("h3", {}, h("span", { class: "step-no" }, String(n)), title), ...content);
          const qty = t.quantity.units_per_carton
            ? `${t.quantity.source_quantity} cartons × ${t.quantity.units_per_carton} units/carton = ${t.quantity.units} units`
            : `${fmt.num(t.quantity.units)} units (no conversion)`;
          const time = t.time.source_time_utc
            ? [`UTC ${t.time.source_time_utc}`, h("br"), `→ Sydney ${fmt.dateTimeSec(t.time.event_ts)}`]
            : `Sydney ${fmt.dateTimeSec(t.time.event_ts)}`;
          const map = (m) => (m.warehouse_code
            ? [h("span", { class: "mono" }, m.source_code), " → ", h("b", {}, m.warehouse_code), h("span", { class: "cell-sub" }, m.basis)]
            : [h("span", { class: "mono" }, m.source_code), " → ", badge("No approved mapping", "danger")]);
          let whBody;
          if (w) {
            whBody = kv([
              ["Event ID", w.event_id], ["Event type", w.event_type],
              ["Product", `${w.product_code} (key ${w.product_key})`], ["Store", `${w.store_code} (key ${w.store_key})`],
              ["Date key", `${w.date_key} · ${fmt.date(w.business_date)}`],
              ["Available change", fmt.signed(w.available_change)], ["Reserved change", fmt.signed(w.reserved_change)],
              w.order_ref ? ["Order / basket", `${w.order_ref}${w.pickup_store_code ? ` · pickup ${w.pickup_store_code}` : ""}`] : null,
              ["ETL run", w.etl_run_id], ["Loaded at", fmt.dateTimeSec(w.loaded_at)],
            ]);
          } else if (s.load_status === "skipped") {
            whBody = h("p", { class: "trace-empty" }, "Not loaded (skipped): ", s.note || "no note");
          } else {
            whBody = h("p", { class: "trace-empty" }, `Not loaded (${s.load_status}). `,
              t.pending_result?.reject_reason || s.note || "", " No warehouse row exists for this record.");
          }
          return h("div", { class: "card-body" }, h("div", { class: "trace" },
            step(1, "Source",
              h("p", { class: "small secondary", style: "margin-bottom:8px" }, `${d.source.system_label} · ${d.source.tables}`),
              rec ? kv(Object.entries(rec).map(([k, v]) => [k.replace(/_/g, " "), v === null ? "—" : /_at$|^sold_at$/.test(k) && typeof v === "string" && v.includes("T") ? fmt.dateTimeSec(v) : String(v)]))
                  : h("p", { class: "trace-empty" }, "Source record not found.")),
            step(2, "Staging", kv([
              ["Table", `etl.${s.stg_table}`], ["Staging ID", s.stg_id], ["Reference", h("span", { class: "mono" }, s.source_ref)],
              ["Captured", fmt.dateTimeSec(s.captured_at)],
              ["Status", badge(s.load_status, STATUS_KIND[s.load_status] || "neutral")],
              s.note ? ["Note", s.note] : null, ["ETL run", s.etl_run_id ?? "—"],
            ])),
            step(3, "Transformation",
              h("p", { class: "small secondary", style: "margin-bottom:8px" }, "Derived from the stored staging fields."),
              kv([
                ["Product code", map(t.product)], ["Store code", map(t.store)],
                ["Quantity", qty], ["Time", time], ["Business date", fmt.date(t.time.business_date)],
                t.pending_result?.reject_reason ? ["Validation", badge(t.pending_result.reject_reason, "danger")] : null,
              ])),
            step(4, "Warehouse", whBody)),
            w ? h("p", { style: "margin-top:12px" }, h("button", { class: "btn btn-small", type: "button",
              onclick: () => app.navigate("inventory", { product: w.product_code, store_sel: w.store_code }) }, "View this store's stock and events")) : null);
        }) });
    }

    needed().catch(() => {});
    return {
      update(next) { params = next; render(); needed().catch(() => {}); },
      reload: () => needed(true),
    };
  },
};
