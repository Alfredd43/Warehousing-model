-- =============================================================================
-- 04_online.sql
-- Purpose: Source 3, the online store.
-- Design ref: docs/Architecture_and_Data_Model.md section 4.3.
-- Prerequisites: 02_store_ops.sql (checkout checks and holds real stock
--                through the store system's find_stock / reserve_stock).
-- Own identifiers: web_sku ('WEB-10001'), collection point code
--                  ('CP-PARRAMATTA'), basket_id, order_no.
-- Outputs: product, online_stock (combined quantity, refreshed by the sync),
--          collection_point, postcode_location, basket + basket_item,
--          checkout_attempt + checkout_attempt_item, web_order +
--          web_order_line, and create_basket(), add_to_basket(),
--          remove_from_basket(), pickup_options(), checkout(),
--          place_online_order() (shortcut).
-- =============================================================================

CREATE TABLE online.product (
    web_sku      text          NOT NULL,
    title        text          NOT NULL,
    web_price    numeric(10,2) NOT NULL,
    pos_barcode  text          NOT NULL,
    CONSTRAINT pk_online_product PRIMARY KEY (web_sku),
    CONSTRAINT ck_online_product_price CHECK (web_price >= 0)
);
COMMENT ON TABLE online.product IS 'Web catalogue. Titles are written for the website and differ from store descriptions.';
COMMENT ON COLUMN online.product.pos_barcode IS
'Barcode the store system needs when the website asks it to hold stock. Operational routing only; the warehouse does not use it for integration.';

CREATE TABLE online.online_stock (
    web_sku             text        NOT NULL,
    available_quantity  integer     NOT NULL DEFAULT 0,
    last_synced_at      timestamptz,
    CONSTRAINT pk_online_stock PRIMARY KEY (web_sku),
    CONSTRAINT fk_online_stock_product FOREIGN KEY (web_sku) REFERENCES online.product (web_sku),
    CONSTRAINT ck_online_stock_available CHECK (available_quantity >= 0)
);
COMMENT ON TABLE online.online_stock IS
'What the website shows: one combined quantity per product for all five stores. Lowered immediately by the website''s own reserved orders; otherwise only dw.run_sync() changes it, so in-store sales, deliveries and store-side cancellations leave it stale until the next sync.';

CREATE TABLE online.collection_point (
    cp_code     text         NOT NULL,
    cp_name     text         NOT NULL,
    latitude    numeric(9,6) NOT NULL,
    longitude   numeric(9,6) NOT NULL,
    store_no    text         NOT NULL,
    CONSTRAINT pk_collection_point PRIMARY KEY (cp_code)
);
COMMENT ON TABLE online.collection_point IS 'Click-and-collect pickup point; one per physical store.';
COMMENT ON COLUMN online.collection_point.store_no IS
'Store number used when calling the store system to hold stock. Operational routing only.';

CREATE TABLE online.postcode_location (
    postcode   text         NOT NULL,
    suburb     text         NOT NULL,
    latitude   numeric(9,6) NOT NULL,
    longitude  numeric(9,6) NOT NULL,
    CONSTRAINT pk_postcode_location PRIMARY KEY (postcode)
);
COMMENT ON TABLE online.postcode_location IS 'Approximate centre of each customer postcode, used to rank collection points by distance.';

-- -----------------------------------------------------------------------------
-- Bag (basket): the customer adds items while browsing. Nothing is held yet.
-- -----------------------------------------------------------------------------
CREATE TABLE online.basket (
    basket_id          bigint      GENERATED ALWAYS AS IDENTITY,
    customer_postcode  text        NOT NULL,
    status             text        NOT NULL DEFAULT 'open',
    created_at         timestamptz NOT NULL DEFAULT now(),
    checked_out_at     timestamptz,
    CONSTRAINT pk_basket PRIMARY KEY (basket_id),
    CONSTRAINT fk_basket_postcode FOREIGN KEY (customer_postcode) REFERENCES online.postcode_location (postcode),
    CONSTRAINT ck_basket_status CHECK (status IN ('open', 'checked_out')),
    CONSTRAINT ck_basket_checked_out CHECK ((status = 'checked_out') = (checked_out_at IS NOT NULL))
);
COMMENT ON TABLE online.basket IS 'A customer''s bag. open = still shopping (or checkout was blocked and the customer is editing it); checked_out = paid and turned into an order.';

CREATE TABLE online.basket_item (
    basket_id            bigint      NOT NULL,
    web_sku              text        NOT NULL,
    quantity             integer     NOT NULL,
    website_qty_at_add   integer     NOT NULL,
    added_at             timestamptz NOT NULL,
    CONSTRAINT pk_basket_item PRIMARY KEY (basket_id, web_sku),
    CONSTRAINT fk_basket_item_basket FOREIGN KEY (basket_id) REFERENCES online.basket (basket_id),
    CONSTRAINT fk_basket_item_product FOREIGN KEY (web_sku) REFERENCES online.product (web_sku),
    CONSTRAINT ck_basket_item_quantity CHECK (quantity > 0)
);
COMMENT ON TABLE online.basket_item IS 'One product in a bag. website_qty_at_add = the (possibly stale) website number the customer saw when adding it.';

-- -----------------------------------------------------------------------------
-- Checkout attempts: the real stock check, BEFORE payment.
-- -----------------------------------------------------------------------------
CREATE TABLE online.checkout_attempt (
    attempt_no      bigint      GENERATED ALWAYS AS IDENTITY,
    basket_id       bigint      NOT NULL,
    pickup_cp_code  text        NOT NULL,
    attempted_at    timestamptz NOT NULL,
    outcome         text        NOT NULL,
    order_no        bigint,
    CONSTRAINT pk_checkout_attempt PRIMARY KEY (attempt_no),
    CONSTRAINT fk_checkout_attempt_basket FOREIGN KEY (basket_id) REFERENCES online.basket (basket_id),
    CONSTRAINT fk_checkout_attempt_pickup FOREIGN KEY (pickup_cp_code) REFERENCES online.collection_point (cp_code),
    CONSTRAINT ck_checkout_attempt_outcome CHECK (outcome IN ('checking', 'paid', 'blocked')),
    CONSTRAINT ck_checkout_attempt_order CHECK ((outcome = 'paid') = (order_no IS NOT NULL))
);
COMMENT ON TABLE online.checkout_attempt IS
'One press of "checkout". paid = every item was really available, payment taken, order created; blocked = at least one item was not available in any single store, so nothing was charged or held and the customer was shown which items to remove.';

CREATE TABLE online.checkout_attempt_item (
    attempt_no          bigint  NOT NULL,
    web_sku             text    NOT NULL,
    quantity            integer NOT NULL,
    website_qty_shown   integer NOT NULL,
    result              text    NOT NULL,
    source_cp_code      text,
    CONSTRAINT pk_checkout_attempt_item PRIMARY KEY (attempt_no, web_sku),
    CONSTRAINT fk_checkout_attempt_item_attempt FOREIGN KEY (attempt_no) REFERENCES online.checkout_attempt (attempt_no),
    CONSTRAINT fk_checkout_attempt_item_product FOREIGN KEY (web_sku) REFERENCES online.product (web_sku),
    CONSTRAINT fk_checkout_attempt_item_source FOREIGN KEY (source_cp_code) REFERENCES online.collection_point (cp_code),
    CONSTRAINT ck_checkout_attempt_item_result CHECK (result IN ('available', 'unavailable')),
    CONSTRAINT ck_checkout_attempt_item_source CHECK ((result = 'available') = (source_cp_code IS NOT NULL))
);
COMMENT ON TABLE online.checkout_attempt_item IS
'Result of the real stock check for one bag item: available (with the store that would supply it) or unavailable (no single store has the whole quantity). website_qty_shown = the website number at checkout.';

-- -----------------------------------------------------------------------------
-- Orders: created only by a paid checkout, so every line is held somewhere.
-- -----------------------------------------------------------------------------
CREATE TABLE online.web_order (
    order_no           bigint      GENERATED BY DEFAULT AS IDENTITY,
    basket_id          bigint      NOT NULL,
    customer_postcode  text        NOT NULL,
    pickup_cp_code     text        NOT NULL,
    status             text        NOT NULL DEFAULT 'paid',
    ordered_at         timestamptz NOT NULL,
    CONSTRAINT pk_web_order PRIMARY KEY (order_no),
    CONSTRAINT uq_web_order_basket UNIQUE (basket_id),
    CONSTRAINT fk_web_order_basket FOREIGN KEY (basket_id) REFERENCES online.basket (basket_id),
    CONSTRAINT fk_web_order_postcode FOREIGN KEY (customer_postcode) REFERENCES online.postcode_location (postcode),
    CONSTRAINT fk_web_order_pickup FOREIGN KEY (pickup_cp_code) REFERENCES online.collection_point (cp_code),
    CONSTRAINT ck_web_order_status CHECK (status = 'paid')
);
COMMENT ON TABLE online.web_order IS
'A paid click-and-collect order, collected at pickup_cp_code (the collection point closest to the customer). Every line was checked against real store stock before payment. Collection and cancellation are tracked by the store system''s reservations.';

CREATE TABLE online.web_order_line (
    order_no              bigint  NOT NULL,
    line_no               integer NOT NULL,
    web_sku               text    NOT NULL,
    quantity              integer NOT NULL,
    website_qty_shown     integer NOT NULL,
    source_cp_code        text    NOT NULL,
    store_reservation_no  bigint  NOT NULL,
    CONSTRAINT pk_web_order_line PRIMARY KEY (order_no, line_no),
    CONSTRAINT uq_web_order_line_sku UNIQUE (order_no, web_sku),
    CONSTRAINT fk_web_order_line_order FOREIGN KEY (order_no) REFERENCES online.web_order (order_no),
    CONSTRAINT fk_web_order_line_product FOREIGN KEY (web_sku) REFERENCES online.product (web_sku),
    CONSTRAINT fk_web_order_line_source FOREIGN KEY (source_cp_code) REFERENCES online.collection_point (cp_code),
    CONSTRAINT ck_web_order_line_quantity CHECK (quantity > 0)
);
COMMENT ON TABLE online.web_order_line IS
'One product on a paid order, held at source_cp_code: the pickup store itself, or another store that transfers it to the pickup store.';

-- Great-circle distance in kilometres between two points (haversine).
CREATE FUNCTION online.distance_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT (2 * 6371 * asin(sqrt(
               power(sin(radians(lat2 - lat1) / 2), 2)
             + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
           )))::numeric(10,2);
$$;

-- -----------------------------------------------------------------------------
-- Bag operations.
-- -----------------------------------------------------------------------------
-- Example: SELECT online.create_basket('2026');
CREATE FUNCTION online.create_basket(p_postcode text, p_at timestamptz DEFAULT now())
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_basket_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM online.postcode_location WHERE postcode = p_postcode) THEN
        RAISE EXCEPTION 'Unknown postcode %', p_postcode;
    END IF;
    INSERT INTO online.basket (customer_postcode, created_at) VALUES (p_postcode, p_at)
    RETURNING basket_id INTO v_basket_id;
    RETURN v_basket_id;
END;
$$;

-- Add (or change the quantity of) an item. The product page only lets the
-- customer add what the website number says is in stock - and that number
-- may be stale. Example: SELECT online.add_to_basket(1, 'WEB-10001', 2);
CREATE FUNCTION online.add_to_basket(
    p_basket_id bigint, p_web_sku text, p_quantity integer, p_at timestamptz DEFAULT now()
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_shown integer;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM online.basket WHERE basket_id = p_basket_id AND status = 'open') THEN
        RAISE EXCEPTION 'Basket % is not open', p_basket_id;
    END IF;
    SELECT available_quantity INTO v_shown FROM online.online_stock WHERE web_sku = p_web_sku;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown web SKU %', p_web_sku;
    END IF;
    IF v_shown < p_quantity THEN
        RAISE EXCEPTION 'Website shows only % of % in stock', v_shown, p_web_sku;
    END IF;

    INSERT INTO online.basket_item (basket_id, web_sku, quantity, website_qty_at_add, added_at)
    VALUES (p_basket_id, p_web_sku, p_quantity, v_shown, p_at)
    ON CONFLICT (basket_id, web_sku) DO UPDATE
       SET quantity = EXCLUDED.quantity,
           website_qty_at_add = EXCLUDED.website_qty_at_add,
           added_at = EXCLUDED.added_at;
END;
$$;

-- Example: SELECT online.remove_from_basket(1, 'WEB-10013');
CREATE FUNCTION online.remove_from_basket(p_basket_id bigint, p_web_sku text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM online.basket WHERE basket_id = p_basket_id AND status = 'open') THEN
        RAISE EXCEPTION 'Basket % is not open', p_basket_id;
    END IF;
    DELETE FROM online.basket_item WHERE basket_id = p_basket_id AND web_sku = p_web_sku;
END;
$$;

-- -----------------------------------------------------------------------------
-- Pickup options for a bag: every store that has at least one bag item (the
-- whole quantity) on its shelf right now. Ranked by fewest transfers, then
-- distance from the customer. A store with none of the items is not offered.
-- items_unavailable > 0 means some item is in no single store, so checkout
-- would be blocked whichever store is chosen.
-- Example: SELECT * FROM online.pickup_options(9);
-- -----------------------------------------------------------------------------
CREATE FUNCTION online.pickup_options(p_basket_id bigint)
RETURNS TABLE (
    option_rank        integer,
    cp_code            text,
    cp_name            text,
    distance_km        numeric,
    items_here         integer,
    items_transferred  integer,
    items_unavailable  integer
)
LANGUAGE sql STABLE AS $$
    WITH customer AS (
        SELECT pl.latitude, pl.longitude
          FROM online.basket b JOIN online.postcode_location pl ON pl.postcode = b.customer_postcode
         WHERE b.basket_id = p_basket_id
    ), item_store AS (
        -- For each bag item: the stores that have the whole quantity.
        SELECT i.web_sku, s.store_no
          FROM online.basket_item i
          JOIN online.product p ON p.web_sku = i.web_sku
          CROSS JOIN LATERAL store_ops.stores_with_stock(p.pos_barcode, i.quantity) AS s (store_no)
         WHERE i.basket_id = p_basket_id
    ), totals AS (
        SELECT count(*)::integer AS n_items,
               count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM item_store x WHERE x.web_sku = i.web_sku))::integer AS n_unavailable
          FROM online.basket_item i WHERE i.basket_id = p_basket_id
    ), per_cp AS (
        SELECT cp.cp_code, cp.cp_name,
               online.distance_km(c.latitude, c.longitude, cp.latitude, cp.longitude) AS distance_km,
               (SELECT count(*) FROM item_store x WHERE x.store_no = cp.store_no)::integer AS items_here
          FROM online.collection_point cp CROSS JOIN customer c
    )
    SELECT (row_number() OVER (ORDER BY pc.items_here DESC, pc.distance_km, pc.cp_code))::integer,
           pc.cp_code, pc.cp_name, pc.distance_km, pc.items_here,
           t.n_items - t.n_unavailable - pc.items_here,
           t.n_unavailable
      FROM per_cp pc CROSS JOIN totals t
     WHERE pc.items_here > 0
     ORDER BY pc.items_here DESC, pc.distance_km, pc.cp_code;
$$;

-- -----------------------------------------------------------------------------
-- Checkout: the real stock check BEFORE payment.
--   1. Pickup store = the one the customer chose from pickup_options(); if
--      none is given, the top option (fewest transfers, then nearest). A store
--      that is not offered (it has none of the items) cannot be chosen.
--   2. For every item, ask the store system which store can supply the whole
--      quantity from REAL shelf stock - the pickup store first, then the
--      other stores by distance from the pickup store (store_ops.find_stock
--      locks those rows, so whoever checks out first gets the stock).
--   3. Any item no single store can supply -> checkout BLOCKED: nothing is
--      charged or held; the attempt lists the unavailable items; the bag stays
--      open (bags never expire) for the customer to edit and try again.
--   4. Otherwise -> payment taken, order created, every item held at its
--      supplying store (store_ops.reserve_stock; items from another store are
--      later transferred to the pickup store), website number lowered. The
--      website number changes only here, never when items go into a bag.
-- Returns the order number, or NULL when blocked.
-- Examples: SELECT online.checkout(9);                       -- top option
--           SELECT online.checkout(9, 'CP-CHATSWOOD');       -- customer's choice
-- -----------------------------------------------------------------------------
CREATE FUNCTION online.checkout(
    p_basket_id       bigint,
    p_pickup_cp_code  text DEFAULT NULL,
    p_at              timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    b               online.basket;
    v_pickup_cp     text;
    v_pickup_store  text;
    v_store_order   text[];
    v_attempt_no    bigint;
    v_item          record;
    v_source_store  text;
    v_blocked       integer := 0;
    v_order_no      bigint;
    v_line_no       integer := 0;
    v_res_no        bigint;
BEGIN
    SELECT * INTO b FROM online.basket WHERE basket_id = p_basket_id FOR UPDATE;
    IF NOT FOUND OR b.status <> 'open' THEN
        RAISE EXCEPTION 'Basket % is not open', p_basket_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM online.basket_item WHERE basket_id = p_basket_id) THEN
        RAISE EXCEPTION 'Basket % is empty', p_basket_id;
    END IF;

    -- 1. Pickup store.
    IF p_pickup_cp_code IS NULL THEN
        SELECT cp_code INTO v_pickup_cp FROM online.pickup_options(p_basket_id) WHERE option_rank = 1;
        IF v_pickup_cp IS NULL THEN
            -- No store has any item: checkout will be blocked; record the closest store.
            SELECT cp.cp_code INTO v_pickup_cp
              FROM online.collection_point cp
              JOIN online.postcode_location pl ON pl.postcode = b.customer_postcode
             ORDER BY online.distance_km(pl.latitude, pl.longitude, cp.latitude, cp.longitude), cp.cp_code
             LIMIT 1;
        END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM online.pickup_options(p_basket_id) WHERE cp_code = p_pickup_cp_code) THEN
            RAISE EXCEPTION 'Pickup store % is not offered for basket % (it has none of the items); choose from online.pickup_options(%)',
                p_pickup_cp_code, p_basket_id, p_basket_id;
        END IF;
        v_pickup_cp := p_pickup_cp_code;
    END IF;

    -- Stores to ask, in order: the pickup store, then the others by distance from it.
    SELECT pk.store_no,
           array_agg(cp.store_no ORDER BY cp.cp_code <> pk.cp_code,
                     online.distance_km(pk.latitude, pk.longitude, cp.latitude, cp.longitude), cp.cp_code)
      INTO v_pickup_store, v_store_order
      FROM online.collection_point pk
     CROSS JOIN online.collection_point cp
     WHERE pk.cp_code = v_pickup_cp
     GROUP BY pk.store_no;

    PERFORM 1 FROM online.online_stock s
      JOIN online.basket_item i ON i.web_sku = s.web_sku AND i.basket_id = p_basket_id
     ORDER BY s.web_sku
       FOR UPDATE OF s;

    INSERT INTO online.checkout_attempt (basket_id, pickup_cp_code, attempted_at, outcome)
    VALUES (p_basket_id, v_pickup_cp, p_at, 'checking')
    RETURNING attempt_no INTO v_attempt_no;

    -- 2. Real stock check for every item (fixed order avoids lock deadlocks).
    FOR v_item IN
        SELECT i.web_sku, i.quantity, p.pos_barcode, s.available_quantity AS shown
          FROM online.basket_item i
          JOIN online.product p ON p.web_sku = i.web_sku
          JOIN online.online_stock s ON s.web_sku = i.web_sku
         WHERE i.basket_id = p_basket_id
         ORDER BY i.web_sku
    LOOP
        v_source_store := store_ops.find_stock(v_item.pos_barcode, v_item.quantity, v_store_order);
        INSERT INTO online.checkout_attempt_item
            (attempt_no, web_sku, quantity, website_qty_shown, result, source_cp_code)
        VALUES
            (v_attempt_no, v_item.web_sku, v_item.quantity, v_item.shown,
             CASE WHEN v_source_store IS NULL THEN 'unavailable' ELSE 'available' END,
             (SELECT cp_code FROM online.collection_point WHERE store_no = v_source_store));
        IF v_source_store IS NULL THEN
            v_blocked := v_blocked + 1;
        END IF;
    END LOOP;

    -- 3. Blocked: nothing charged, nothing held, bag stays open.
    IF v_blocked > 0 THEN
        UPDATE online.checkout_attempt SET outcome = 'blocked' WHERE attempt_no = v_attempt_no;
        RETURN NULL;
    END IF;

    -- 4. Paid: create the order and hold every item.
    v_order_no := nextval(pg_get_serial_sequence('online.web_order', 'order_no'));
    INSERT INTO online.web_order (order_no, basket_id, customer_postcode, pickup_cp_code, ordered_at)
    VALUES (v_order_no, p_basket_id, b.customer_postcode, v_pickup_cp, p_at);

    FOR v_item IN
        SELECT a.web_sku, a.quantity, a.website_qty_shown, a.source_cp_code, cp.store_no, p.pos_barcode
          FROM online.checkout_attempt_item a
          JOIN online.collection_point cp ON cp.cp_code = a.source_cp_code
          JOIN online.product p ON p.web_sku = a.web_sku
         WHERE a.attempt_no = v_attempt_no
         ORDER BY a.web_sku
    LOOP
        v_line_no := v_line_no + 1;
        v_res_no := store_ops.reserve_stock(v_item.store_no, v_item.pos_barcode, v_item.quantity,
                                            v_order_no::text, v_line_no, v_pickup_store, p_at);
        IF v_res_no IS NULL THEN   -- cannot happen: the rows are locked by find_stock
            RAISE EXCEPTION 'Stock for % changed during checkout', v_item.web_sku;
        END IF;
        INSERT INTO online.web_order_line
            (order_no, line_no, web_sku, quantity, website_qty_shown, source_cp_code, store_reservation_no)
        VALUES
            (v_order_no, v_line_no, v_item.web_sku, v_item.quantity, v_item.website_qty_shown,
             v_item.source_cp_code, v_res_no);
        -- The website deducts its own sale immediately (never below zero).
        UPDATE online.online_stock
           SET available_quantity = greatest(available_quantity - v_item.quantity, 0)
         WHERE web_sku = v_item.web_sku;
    END LOOP;

    UPDATE online.checkout_attempt SET outcome = 'paid', order_no = v_order_no WHERE attempt_no = v_attempt_no;
    UPDATE online.basket SET status = 'checked_out', checked_out_at = p_at WHERE basket_id = p_basket_id;
    RETURN v_order_no;
END;
$$;

-- -----------------------------------------------------------------------------
-- Shortcut used by scripts and tests: new bag + add items + checkout (at the
-- chosen pickup store, or the top option if none is given).
-- Returns the order number, or NULL if checkout was blocked (the bag is left
-- open; see online.checkout_attempt for which items were unavailable).
-- Example: SELECT online.place_online_order('2026', ARRAY['WEB-10003','WEB-10013'], ARRAY[2,2]);
-- -----------------------------------------------------------------------------
CREATE FUNCTION online.place_online_order(
    p_postcode        text,
    p_web_skus        text[],
    p_quantities      integer[],
    p_ordered_at      timestamptz DEFAULT now(),
    p_pickup_cp_code  text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_basket_id bigint;
    v_item      record;
BEGIN
    IF coalesce(array_length(p_web_skus, 1), 0) = 0
       OR array_length(p_web_skus, 1) <> coalesce(array_length(p_quantities, 1), 0) THEN
        RAISE EXCEPTION 'Give one quantity per web SKU';
    END IF;
    v_basket_id := online.create_basket(p_postcode, p_ordered_at);
    FOR v_item IN SELECT * FROM unnest(p_web_skus, p_quantities) AS i (web_sku, quantity) LOOP
        PERFORM online.add_to_basket(v_basket_id, v_item.web_sku, v_item.quantity, p_ordered_at);
    END LOOP;
    RETURN online.checkout(v_basket_id, p_pickup_cp_code, p_ordered_at);
END;
$$;

-- One-product form. Example: SELECT online.place_online_order('2026', 'WEB-10001', 2);
CREATE FUNCTION online.place_online_order(
    p_postcode    text,
    p_web_sku     text,
    p_quantity    integer,
    p_ordered_at  timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE sql AS $$
    SELECT online.place_online_order(p_postcode, ARRAY[p_web_sku], ARRAY[p_quantity], p_ordered_at);
$$;
