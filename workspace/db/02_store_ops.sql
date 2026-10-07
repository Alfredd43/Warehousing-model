-- =============================================================================
-- 02_store_ops.sql
-- Purpose: Source 1, the store system used by the five physical stores
--          (POS tills, stock screens, click-and-collect counter, transfers).
-- Design ref: docs/Architecture_and_Data_Model.md section 4.1.
-- Prerequisites: 01_schemas.sql.
-- Identifiers: item_no ('P001'), the item number shared by all three systems;
--   store_no ('101'..'105'), this system's own store code. Transaction ID:
--   sale_no, the receipt number. The EAN-13 barcode is a product attribute.
-- Outputs: store, product, store_stock, sale, sale_line, reservation and the
--          store system's operations:
--            record_sale()              till sale of one or more items
--            receive_goods()            goods put on the shelf (called by Source 2)
--            find_stock()               checkout: which store can supply a line (called by Source 3)
--            reserve_stock()            hold stock for one online order line (called by Source 3)
--            dispatch_order_transfers() send an order's lines held elsewhere to its pickup store
--            receive_order_transfers()  pickup store books those lines in
--            collect_order()            customer collects the whole order at the pickup store
--            cancel_order()             order cancelled, held stock back on a shelf
--            cancel_overdue_orders()    housekeeping: cancel orders not collected in time
--            stores_with_stock()        which stores could supply a line (called by Source 3)
--            shelf_totals()             units on the shelf per product, all stores (website sync)
-- =============================================================================

-- EAN-13 check digit: weights 1,3,1,3... over the first 12 digits.
CREATE FUNCTION store_ops.is_valid_ean13(p_barcode text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_barcode ~ '^[0-9]{13}$'
       AND (10 - (SELECT sum(substr(p_barcode, i, 1)::int * CASE WHEN i % 2 = 0 THEN 3 ELSE 1 END)
                    FROM generate_series(1, 12) AS i) % 10) % 10
           = substr(p_barcode, 13, 1)::int;
$$;

CREATE TABLE store_ops.store (
    store_no    text NOT NULL,
    store_name  text NOT NULL,
    suburb      text NOT NULL,
    postcode    text NOT NULL,
    CONSTRAINT pk_store PRIMARY KEY (store_no),
    CONSTRAINT ck_store_no CHECK (store_no ~ '^[0-9]{3}$'),
    CONSTRAINT ck_store_postcode CHECK (postcode ~ '^[0-9]{4}$')
);
COMMENT ON TABLE store_ops.store IS 'One physical PetHaven store, identified by its three-digit store number.';

CREATE TABLE store_ops.product (
    item_no      text          NOT NULL,
    barcode      text          NOT NULL,
    description  text          NOT NULL,
    category     text          NOT NULL,
    shelf_price  numeric(10,2) NOT NULL,
    CONSTRAINT pk_product PRIMARY KEY (item_no),
    CONSTRAINT uq_product_barcode UNIQUE (barcode),
    CONSTRAINT ck_product_item_no CHECK (item_no ~ '^P[0-9]{3}$'),
    CONSTRAINT ck_product_barcode CHECK (store_ops.is_valid_ean13(barcode)),
    CONSTRAINT ck_product_price CHECK (shelf_price >= 0)
);
COMMENT ON TABLE store_ops.product IS
'Store product catalogue, keyed on the item number shared by every system (P001...). System of record for product descriptions, categories and prices.';
COMMENT ON COLUMN store_ops.product.item_no IS 'Item number: the same in the store system, the supplier delivery system and the online store.';
COMMENT ON COLUMN store_ops.product.barcode IS 'EAN-13 barcode printed on the pack (check digit enforced). An attribute the till scans, not a key between systems.';

CREATE TABLE store_ops.store_stock (
    store_no           text        NOT NULL,
    item_no            text        NOT NULL,
    in_store_quantity  integer     NOT NULL DEFAULT 0,
    reserved_quantity  integer     NOT NULL DEFAULT 0,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_store_stock PRIMARY KEY (store_no, item_no),
    CONSTRAINT fk_store_stock_store FOREIGN KEY (store_no) REFERENCES store_ops.store (store_no),
    CONSTRAINT fk_store_stock_product FOREIGN KEY (item_no) REFERENCES store_ops.product (item_no),
    CONSTRAINT ck_store_stock_in_store CHECK (in_store_quantity >= 0),
    CONSTRAINT ck_store_stock_reserved CHECK (reserved_quantity >= 0)
);
COMMENT ON TABLE store_ops.store_stock IS
'Live stock: one row per product per store. The real number; changes instantly on every sale, supplier delivery, reservation, transfer, collection and cancellation.';
COMMENT ON COLUMN store_ops.store_stock.in_store_quantity IS 'Units on the shelf and free to sell.';
COMMENT ON COLUMN store_ops.store_stock.reserved_quantity IS
'Units set aside for online orders at this store: held here for collection, or held here waiting to be sent to another pickup store. Units in transit belong to no store.';

CREATE TABLE store_ops.sale (
    sale_no   bigint      GENERATED ALWAYS AS IDENTITY,
    store_no  text        NOT NULL,
    till_no   integer     NOT NULL,
    sold_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_sale PRIMARY KEY (sale_no),
    CONSTRAINT fk_sale_store FOREIGN KEY (store_no) REFERENCES store_ops.store (store_no)
);
COMMENT ON TABLE store_ops.sale IS 'One completed till transaction (receipt). Never updated.';
COMMENT ON COLUMN store_ops.sale.sale_no IS 'Receipt number: the in-store transaction ID.';

CREATE TABLE store_ops.sale_line (
    sale_no     bigint        NOT NULL,
    line_no     integer       NOT NULL,
    item_no     text          NOT NULL,
    quantity    integer       NOT NULL,
    unit_price  numeric(10,2) NOT NULL,
    CONSTRAINT pk_sale_line PRIMARY KEY (sale_no, line_no),
    CONSTRAINT fk_sale_line_sale FOREIGN KEY (sale_no) REFERENCES store_ops.sale (sale_no),
    CONSTRAINT fk_sale_line_product FOREIGN KEY (item_no) REFERENCES store_ops.product (item_no),
    CONSTRAINT ck_sale_line_quantity CHECK (quantity > 0)
);
COMMENT ON TABLE store_ops.sale_line IS
'One item on a receipt. Inserting a line deducts the quantity from that store''s shelf immediately (trigger).';

CREATE TABLE store_ops.reservation (
    reservation_no   bigint      GENERATED ALWAYS AS IDENTITY,
    store_no         text        NOT NULL,
    pickup_store_no  text        NOT NULL,
    item_no          text        NOT NULL,
    quantity         integer     NOT NULL,
    web_order_ref    text        NOT NULL,
    web_line_no      integer     NOT NULL,
    status           text        NOT NULL DEFAULT 'held',
    reserved_at      timestamptz NOT NULL,
    dispatched_at    timestamptz,
    arrived_at       timestamptz,
    closed_at        timestamptz,
    cancel_reason    text,
    CONSTRAINT pk_reservation PRIMARY KEY (reservation_no),
    CONSTRAINT uq_reservation_order_line UNIQUE (web_order_ref, web_line_no),
    CONSTRAINT fk_reservation_stock FOREIGN KEY (store_no, item_no) REFERENCES store_ops.store_stock (store_no, item_no),
    CONSTRAINT fk_reservation_pickup FOREIGN KEY (pickup_store_no) REFERENCES store_ops.store (store_no),
    CONSTRAINT ck_reservation_quantity CHECK (quantity > 0),
    CONSTRAINT ck_reservation_status CHECK (status IN ('held', 'in_transit', 'arrived', 'collected', 'cancelled')),
    CONSTRAINT ck_reservation_transfer CHECK (status NOT IN ('in_transit', 'arrived') OR store_no <> pickup_store_no),
    CONSTRAINT ck_reservation_closed CHECK ((status IN ('collected', 'cancelled')) = (closed_at IS NOT NULL)),
    CONSTRAINT ck_reservation_reason CHECK ((status = 'cancelled') = (cancel_reason IS NOT NULL))
);
COMMENT ON TABLE store_ops.reservation IS
'Stock held for one online order line. store_no = store the units were taken from; pickup_store_no = store where the customer collects. Same store: held -> collected/cancelled. Different store (transfer): held -> in_transit -> arrived -> collected/cancelled.';
COMMENT ON COLUMN store_ops.reservation.web_order_ref IS 'Order ID of the online order (online.web_order.order_no), as text. The store system does not validate it.';


-- -----------------------------------------------------------------------------
-- In-store sale: deduct the shelf stock as each line is saved; refuse the line
-- (and so the whole receipt) if the shelf does not have enough.
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.apply_sale_line() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_store_no text;
    v_sold_at  timestamptz;
BEGIN
    SELECT store_no, sold_at INTO v_store_no, v_sold_at
      FROM store_ops.sale WHERE sale_no = NEW.sale_no;

    UPDATE store_ops.store_stock
       SET in_store_quantity = in_store_quantity - NEW.quantity,
           updated_at        = v_sold_at
     WHERE store_no = v_store_no
       AND item_no = NEW.item_no
       AND in_store_quantity >= NEW.quantity;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Store % does not have % unit(s) of % on the shelf',
            v_store_no, NEW.quantity, NEW.item_no;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sale_line_deduct_stock
BEFORE INSERT ON store_ops.sale_line
FOR EACH ROW EXECUTE FUNCTION store_ops.apply_sale_line();

-- Till sale of one or more items, saved as one receipt in one transaction.
-- Example: SELECT store_ops.record_sale('101', ARRAY['P001','P005'], ARRAY[2,1]);
-- Returns the receipt number (sale_no).
CREATE FUNCTION store_ops.record_sale(
    p_store_no    text,
    p_item_nos    text[],
    p_quantities  integer[],
    p_sold_at     timestamptz DEFAULT now(),
    p_till_no     integer DEFAULT 1
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_sale_no bigint;
BEGIN
    IF coalesce(array_length(p_item_nos, 1), 0) = 0
       OR array_length(p_item_nos, 1) <> coalesce(array_length(p_quantities, 1), 0) THEN
        RAISE EXCEPTION 'Give one quantity per item';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_item_nos) AS b (item_no)
                WHERE NOT EXISTS (SELECT 1 FROM store_ops.product p WHERE p.item_no = b.item_no)) THEN
        RAISE EXCEPTION 'Unknown item number in %', p_item_nos;
    END IF;

    INSERT INTO store_ops.sale (store_no, till_no, sold_at)
    VALUES (p_store_no, p_till_no, p_sold_at)
    RETURNING sale_no INTO v_sale_no;

    INSERT INTO store_ops.sale_line (sale_no, line_no, item_no, quantity, unit_price)
    SELECT v_sale_no, i.n, i.item_no, i.quantity, p.shelf_price
      FROM unnest(p_item_nos, p_quantities) WITH ORDINALITY AS i (item_no, quantity, n)
      JOIN store_ops.product p ON p.item_no = i.item_no
     ORDER BY i.n;

    RETURN v_sale_no;
END;
$$;


-- -----------------------------------------------------------------------------
-- Interface used by Source 2: goods delivered to a store go on the shelf.
-- The first supplier delivery of a product to a store creates its stock row.
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.receive_goods(
    p_store_no text, p_item_no text, p_units integer, p_received_at timestamptz
) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO store_ops.store_stock (store_no, item_no, in_store_quantity, reserved_quantity, updated_at)
    VALUES (p_store_no, p_item_no, p_units, 0, p_received_at)
    ON CONFLICT (store_no, item_no) DO UPDATE
       SET in_store_quantity = store_ops.store_stock.in_store_quantity + EXCLUDED.in_store_quantity,
           updated_at        = EXCLUDED.updated_at;
$$;


-- -----------------------------------------------------------------------------
-- Interface used by Source 3's website sync: units on the shelf per product,
-- summed over all stores. Reserved units are not available, so not counted.
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.shelf_totals()
RETURNS TABLE (item_no text, in_store_total integer)
LANGUAGE sql STABLE AS $$
    SELECT item_no, sum(in_store_quantity)::integer
      FROM store_ops.store_stock
     GROUP BY item_no;
$$;


-- -----------------------------------------------------------------------------
-- Interface used by Source 3 to offer pickup stores: which stores have the
-- whole quantity on the shelf right now? Read-only, no locks.
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.stores_with_stock(p_item_no text, p_quantity integer)
RETURNS SETOF text
LANGUAGE sql STABLE AS $$
    SELECT store_no FROM store_ops.store_stock
     WHERE item_no = p_item_no AND in_store_quantity >= p_quantity;
$$;


-- -----------------------------------------------------------------------------
-- Interface used by Source 3 at checkout: which store can supply the whole
-- quantity? Tries the stores in the order given (pickup store first, then by
-- distance) and returns the first with enough on the shelf, or NULL. The
-- product's stock rows are locked until the caller's transaction ends, so
-- the answer stays true while the website takes payment and holds the stock.
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.find_stock(
    p_item_no text, p_quantity integer, p_store_nos text[]
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_store_no text;
BEGIN
    PERFORM 1 FROM store_ops.store_stock
     WHERE item_no = p_item_no AND store_no = ANY (p_store_nos)
     ORDER BY store_no
       FOR UPDATE;

    SELECT s.store_no INTO v_store_no
      FROM unnest(p_store_nos) WITH ORDINALITY AS u (store_no, n)
      JOIN store_ops.store_stock s ON s.store_no = u.store_no AND s.item_no = p_item_no
     WHERE s.in_store_quantity >= p_quantity
     ORDER BY u.n
     LIMIT 1;
    RETURN v_store_no;
END;
$$;


-- -----------------------------------------------------------------------------
-- Interface used by Source 3: hold stock at p_store_no for one online order
-- line that will be collected at p_pickup_store_no (the same store, or another
-- store it will be transferred to). Returns the reservation number, or NULL if
-- this store does not have the whole quantity on the shelf.
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.reserve_stock(
    p_store_no text, p_item_no text, p_quantity integer,
    p_web_order_ref text, p_web_line_no integer,
    p_pickup_store_no text, p_reserved_at timestamptz
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_reservation_no bigint;
BEGIN
    UPDATE store_ops.store_stock
       SET in_store_quantity = in_store_quantity - p_quantity,
           reserved_quantity = reserved_quantity + p_quantity,
           updated_at        = p_reserved_at
     WHERE store_no = p_store_no
       AND item_no = p_item_no
       AND in_store_quantity >= p_quantity;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    INSERT INTO store_ops.reservation
        (store_no, pickup_store_no, item_no, quantity, web_order_ref, web_line_no, reserved_at)
    VALUES
        (p_store_no, p_pickup_store_no, p_item_no, p_quantity, p_web_order_ref, p_web_line_no, p_reserved_at)
    RETURNING reservation_no INTO v_reservation_no;
    RETURN v_reservation_no;
END;
$$;


-- -----------------------------------------------------------------------------
-- Transfers to the pickup store.
--   Dispatch: units leave the source store's back room (reserved there - qty)
--             and are in transit, belonging to no store.
--   Receive:  units arrive at the pickup store (reserved there + qty).
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.dispatch_order_transfers(
    p_web_order_ref text, p_dispatched_at timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    r       store_ops.reservation;
    v_count integer := 0;
BEGIN
    FOR r IN
        SELECT * FROM store_ops.reservation
         WHERE web_order_ref = p_web_order_ref AND status = 'held' AND store_no <> pickup_store_no
         ORDER BY web_line_no
           FOR UPDATE
    LOOP
        UPDATE store_ops.store_stock
           SET reserved_quantity = reserved_quantity - r.quantity,
               updated_at        = p_dispatched_at
         WHERE store_no = r.store_no AND item_no = r.item_no;
        UPDATE store_ops.reservation
           SET status = 'in_transit', dispatched_at = p_dispatched_at
         WHERE reservation_no = r.reservation_no;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;

CREATE FUNCTION store_ops.receive_order_transfers(
    p_web_order_ref text, p_arrived_at timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    r       store_ops.reservation;
    v_count integer := 0;
BEGIN
    FOR r IN
        SELECT * FROM store_ops.reservation
         WHERE web_order_ref = p_web_order_ref AND status = 'in_transit'
         ORDER BY web_line_no
           FOR UPDATE
    LOOP
        INSERT INTO store_ops.store_stock (store_no, item_no, in_store_quantity, reserved_quantity, updated_at)
        VALUES (r.pickup_store_no, r.item_no, 0, r.quantity, p_arrived_at)
        ON CONFLICT (store_no, item_no) DO UPDATE
           SET reserved_quantity = store_ops.store_stock.reserved_quantity + EXCLUDED.reserved_quantity,
               updated_at        = EXCLUDED.updated_at;
        UPDATE store_ops.reservation
           SET status = 'arrived', arrived_at = p_arrived_at
         WHERE reservation_no = r.reservation_no;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;


-- -----------------------------------------------------------------------------
-- Customer collects the whole order at the pickup store. Allowed only when
-- every open line is at the pickup store (held there, or arrived).
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.collect_order(
    p_web_order_ref text, p_collected_at timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    r       store_ops.reservation;
    v_count integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM store_ops.reservation
                WHERE web_order_ref = p_web_order_ref
                  AND (status = 'in_transit' OR (status = 'held' AND store_no <> pickup_store_no))) THEN
        RAISE EXCEPTION 'Order % is not ready: some items have not reached the pickup store yet', p_web_order_ref;
    END IF;

    FOR r IN
        SELECT * FROM store_ops.reservation
         WHERE web_order_ref = p_web_order_ref AND status IN ('held', 'arrived')
         ORDER BY web_line_no
           FOR UPDATE
    LOOP
        UPDATE store_ops.store_stock
           SET reserved_quantity = reserved_quantity - r.quantity,
               updated_at        = p_collected_at
         WHERE store_no = r.pickup_store_no AND item_no = r.item_no;
        UPDATE store_ops.reservation
           SET status = 'collected', closed_at = p_collected_at
         WHERE reservation_no = r.reservation_no;
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Order % has nothing waiting for collection', p_web_order_ref;
    END IF;
    RETURN v_count;
END;
$$;

-- Order cancelled before collection: each held line goes back on the shelf of
-- the store where it now is (its source store, or the pickup store if it has
-- arrived). Refused while any line is in transit.
CREATE FUNCTION store_ops.cancel_order(
    p_web_order_ref text, p_reason text, p_cancelled_at timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    r        store_ops.reservation;
    v_where  text;
    v_count  integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM store_ops.reservation
                WHERE web_order_ref = p_web_order_ref AND status = 'in_transit') THEN
        RAISE EXCEPTION 'Order % has items in transit; receive them before cancelling', p_web_order_ref;
    END IF;

    FOR r IN
        SELECT * FROM store_ops.reservation
         WHERE web_order_ref = p_web_order_ref AND status IN ('held', 'arrived')
         ORDER BY web_line_no
           FOR UPDATE
    LOOP
        v_where := CASE WHEN r.status = 'arrived' THEN r.pickup_store_no ELSE r.store_no END;
        UPDATE store_ops.store_stock
           SET reserved_quantity = reserved_quantity - r.quantity,
               in_store_quantity = in_store_quantity + r.quantity,
               updated_at        = p_cancelled_at
         WHERE store_no = v_where AND item_no = r.item_no;
        UPDATE store_ops.reservation
           SET status = 'cancelled', closed_at = p_cancelled_at, cancel_reason = p_reason
         WHERE reservation_no = r.reservation_no;
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Order % has nothing to cancel', p_web_order_ref;
    END IF;
    RETURN v_count;
END;
$$;


-- -----------------------------------------------------------------------------
-- Housekeeping: cancel click-and-collect orders not collected within
-- p_days of being placed. Every held item goes back on the shelf where it
-- is now (cancel_order). Orders with an item still in transit are left for
-- the next run, since they cannot be cancelled until it arrives.
-- Returns the number of orders cancelled.
-- Example: SELECT store_ops.cancel_overdue_orders();
-- -----------------------------------------------------------------------------
CREATE FUNCTION store_ops.cancel_overdue_orders(
    p_days integer DEFAULT 3, p_at timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_order  text;
    v_count  integer := 0;
BEGIN
    FOR v_order IN
        SELECT web_order_ref
          FROM store_ops.reservation
         WHERE status IN ('held', 'in_transit', 'arrived')
         GROUP BY web_order_ref
        HAVING min(reserved_at) < p_at - make_interval(days => p_days)
           AND bool_and(status <> 'in_transit')
         ORDER BY min(reserved_at)
    LOOP
        PERFORM store_ops.cancel_order(v_order, format('Not collected within %s days', p_days), p_at);
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;
