-- =============================================================================
-- 03_supply.sql
-- Purpose: Source 2, the supplier delivery system.
-- Design ref: docs/Architecture_and_Data_Model.md section 4.2.
-- Prerequisites: 02_store_ops.sql (a supplier delivery puts goods on the store shelf).
-- Identifiers: item_no ('P001'), the item number shared by all three systems;
--   location_code ('NSW-PARRA'), this system's own store code; supplier_id
--   ('SUP-01'). Transaction ID: the supplier's order number (supplier_order_no)
--   on each delivery. Formats deliberately different from the stores:
--   quantities in CARTONS, times in UTC.
-- Outputs: supplier, location, item, supplier_delivery, supplier_delivery_line,
--          record_supplier_delivery() and the trigger that puts delivered
--          units on the store shelf immediately.
-- =============================================================================

CREATE TABLE supply.supplier (
    supplier_id    text NOT NULL,
    supplier_name  text NOT NULL,
    CONSTRAINT pk_supplier PRIMARY KEY (supplier_id),
    CONSTRAINT ck_supplier_id CHECK (supplier_id ~ '^SUP-[0-9]{2}$')
);
COMMENT ON TABLE supply.supplier IS 'A company that supplies PetHaven, identified by its supplier ID.';

CREATE TABLE supply.location (
    location_code  text NOT NULL,
    location_name  text NOT NULL,
    ship_to_store  text NOT NULL,
    CONSTRAINT pk_location PRIMARY KEY (location_code)
);
COMMENT ON TABLE supply.location IS 'Supplier delivery destination as known to the supplier delivery system.';
COMMENT ON COLUMN supply.location.ship_to_store IS
'Store number printed on the supplier delivery docket, so the store system can book the goods in. Operational routing only; the warehouse does not use it for integration.';

CREATE TABLE supply.item (
    item_no           text    NOT NULL,
    item_description  text    NOT NULL,
    supplier_id       text    NOT NULL,
    gtin14            text    NOT NULL,
    units_per_carton  integer NOT NULL,
    CONSTRAINT pk_item PRIMARY KEY (item_no),
    CONSTRAINT fk_item_supplier FOREIGN KEY (supplier_id) REFERENCES supply.supplier (supplier_id),
    CONSTRAINT ck_item_gtin14 CHECK (gtin14 ~ '^[0-9]{14}$'),
    CONSTRAINT ck_item_units_per_carton CHECK (units_per_carton > 0)
);
COMMENT ON TABLE supply.item IS 'Item as the supplier delivery system knows it: ordered and delivered in cartons.';
COMMENT ON COLUMN supply.item.item_no IS 'Item number: the same in the store system, the supplier delivery system and the online store.';
COMMENT ON COLUMN supply.item.supplier_id IS 'The supplier this item is ordered from.';
COMMENT ON COLUMN supply.item.gtin14 IS 'GTIN-14 printed on the carton (EAN-13 with a leading 0). An attribute, not a key between systems.';
COMMENT ON COLUMN supply.item.units_per_carton IS 'Retail units in one carton; the ETL converts cartons to units with it.';

CREATE TABLE supply.supplier_delivery (
    delivery_no        bigint    GENERATED ALWAYS AS IDENTITY,
    location_code      text      NOT NULL,
    supplier_id        text      NOT NULL,
    supplier_order_no  text      NOT NULL,
    delivered_at_utc   timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    CONSTRAINT pk_supplier_delivery PRIMARY KEY (delivery_no),
    CONSTRAINT uq_supplier_delivery_order UNIQUE (supplier_id, supplier_order_no),
    CONSTRAINT fk_supplier_delivery_location FOREIGN KEY (location_code) REFERENCES supply.location (location_code),
    CONSTRAINT fk_supplier_delivery_supplier FOREIGN KEY (supplier_id) REFERENCES supply.supplier (supplier_id)
);
COMMENT ON TABLE supply.supplier_delivery IS 'One supplier delivery (docket) to one location, filling one supplier order.';
COMMENT ON COLUMN supply.supplier_delivery.delivery_no IS 'Internal docket number of the supplier delivery system.';
COMMENT ON COLUMN supply.supplier_delivery.supplier_order_no IS
'Supplier order number: the supplier transaction ID, unique per supplier. Every warehouse event from this delivery traces back to it.';
COMMENT ON COLUMN supply.supplier_delivery.delivered_at_utc IS 'Supplier delivery time in UTC, without time zone (the supplier delivery system''s convention).';

CREATE TABLE supply.supplier_delivery_line (
    delivery_no  bigint  NOT NULL,
    line_no      integer NOT NULL,
    item_no      text    NOT NULL,
    cartons      integer NOT NULL,
    CONSTRAINT pk_supplier_delivery_line PRIMARY KEY (delivery_no, line_no),
    CONSTRAINT fk_supplier_delivery_line_supplier_delivery FOREIGN KEY (delivery_no) REFERENCES supply.supplier_delivery (delivery_no),
    CONSTRAINT fk_supplier_delivery_line_item FOREIGN KEY (item_no) REFERENCES supply.item (item_no),
    CONSTRAINT ck_supplier_delivery_line_cartons CHECK (cartons > 0)
);
COMMENT ON TABLE supply.supplier_delivery_line IS
'One item on a supplier delivery, in cartons. Saving the line puts cartons x units_per_carton units on the store shelf immediately (trigger).';

-- A supplier delivery is on the shelf as soon as it is recorded: convert the
-- cartons to units and call the store system's receiving interface.
CREATE FUNCTION supply.apply_supplier_delivery_line() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_store_no  text;
    v_units     integer;
    v_at        timestamptz;
BEGIN
    SELECT l.ship_to_store, d.delivered_at_utc AT TIME ZONE 'UTC'
      INTO v_store_no, v_at
      FROM supply.supplier_delivery d
      JOIN supply.location l ON l.location_code = d.location_code
     WHERE d.delivery_no = NEW.delivery_no;

    SELECT NEW.cartons * i.units_per_carton INTO v_units
      FROM supply.item i WHERE i.item_no = NEW.item_no;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown item number %', NEW.item_no;
    END IF;

    PERFORM store_ops.receive_goods(v_store_no, NEW.item_no, v_units, v_at);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_supplier_delivery_line_to_store
BEFORE INSERT ON supply.supplier_delivery_line
FOR EACH ROW EXECUTE FUNCTION supply.apply_supplier_delivery_line();

-- Record one supplier delivery docket (one supplier order) with one or more items.
-- p_supplier_order_no NULL = the system numbers it (PO-<docket number>).
-- Example: SELECT supply.record_supplier_delivery('NSW-CHATS', 'SUP-01', 'PO-2001', ARRAY['P001'], ARRAY[5]);
CREATE FUNCTION supply.record_supplier_delivery(
    p_location_code      text,
    p_supplier_id        text,
    p_supplier_order_no  text,
    p_item_nos           text[],
    p_cartons            integer[],
    p_delivered_at_utc   timestamp DEFAULT (now() AT TIME ZONE 'UTC')
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_delivery_no bigint;
BEGIN
    IF coalesce(array_length(p_item_nos, 1), 0) = 0
       OR array_length(p_item_nos, 1) <> coalesce(array_length(p_cartons, 1), 0) THEN
        RAISE EXCEPTION 'Give one carton count per item';
    END IF;

    v_delivery_no := nextval(pg_get_serial_sequence('supply.supplier_delivery', 'delivery_no'));
    INSERT INTO supply.supplier_delivery (delivery_no, location_code, supplier_id, supplier_order_no, delivered_at_utc)
    OVERRIDING SYSTEM VALUE
    VALUES (v_delivery_no, p_location_code, p_supplier_id,
            coalesce(p_supplier_order_no, format('PO-%s', 9000 + v_delivery_no)), p_delivered_at_utc);

    INSERT INTO supply.supplier_delivery_line (delivery_no, line_no, item_no, cartons)
    SELECT v_delivery_no, i.n, i.item_no, i.cartons
      FROM unnest(p_item_nos, p_cartons) WITH ORDINALITY AS i (item_no, cartons, n)
     ORDER BY i.n;

    RETURN v_delivery_no;
END;
$$;
