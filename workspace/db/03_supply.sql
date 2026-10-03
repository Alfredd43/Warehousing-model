-- =============================================================================
-- 03_supply.sql
-- Purpose: Source 2, the warehouse/delivery system.
-- Design ref: docs/Architecture_and_Data_Model.md section 4.2.
-- Prerequisites: 02_store_ops.sql (a delivery puts goods on the store shelf).
-- Own identifiers and formats (deliberately different from the stores):
--   location_code ('NSW-PARRA'), supplier_sku ('PF-DOG-ADT-3K'),
--   GTIN-14 carton barcodes, quantities in CARTONS, times in UTC.
-- Outputs: location, item, delivery, delivery_line, record_delivery() and the
--          trigger that puts delivered units on the store shelf immediately.
-- =============================================================================

CREATE TABLE supply.location (
    location_code  text NOT NULL,
    location_name  text NOT NULL,
    ship_to_store  text NOT NULL,
    CONSTRAINT pk_location PRIMARY KEY (location_code)
);
COMMENT ON TABLE supply.location IS 'Delivery destination as known to the delivery system.';
COMMENT ON COLUMN supply.location.ship_to_store IS
'Store number printed on the delivery docket, so the store system can book the goods in. Operational routing only; the warehouse does not use it for integration.';

CREATE TABLE supply.item (
    supplier_sku      text    NOT NULL,
    item_description  text    NOT NULL,
    gtin14            text    NOT NULL,
    units_per_carton  integer NOT NULL,
    CONSTRAINT pk_item PRIMARY KEY (supplier_sku),
    CONSTRAINT ck_item_gtin14 CHECK (gtin14 ~ '^[0-9]{14}$'),
    CONSTRAINT ck_item_units_per_carton CHECK (units_per_carton > 0)
);
COMMENT ON TABLE supply.item IS 'Supplier item, ordered and delivered in cartons.';
COMMENT ON COLUMN supply.item.gtin14 IS
'GTIN-14 of the retail unit (EAN-13 with a leading 0), scanned by the store when booking in. Operational routing only.';

CREATE TABLE supply.delivery (
    delivery_no       bigint    GENERATED ALWAYS AS IDENTITY,
    location_code     text      NOT NULL,
    supplier_name     text      NOT NULL,
    delivered_at_utc  timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    CONSTRAINT pk_delivery PRIMARY KEY (delivery_no),
    CONSTRAINT fk_delivery_location FOREIGN KEY (location_code) REFERENCES supply.location (location_code)
);
COMMENT ON TABLE supply.delivery IS 'One supplier delivery (docket) to one location.';
COMMENT ON COLUMN supply.delivery.delivered_at_utc IS 'Delivery time in UTC, without time zone (the delivery system''s convention).';

CREATE TABLE supply.delivery_line (
    delivery_no   bigint  NOT NULL,
    line_no       integer NOT NULL,
    supplier_sku  text    NOT NULL,
    cartons       integer NOT NULL,
    CONSTRAINT pk_delivery_line PRIMARY KEY (delivery_no, line_no),
    CONSTRAINT fk_delivery_line_delivery FOREIGN KEY (delivery_no) REFERENCES supply.delivery (delivery_no),
    CONSTRAINT fk_delivery_line_item FOREIGN KEY (supplier_sku) REFERENCES supply.item (supplier_sku),
    CONSTRAINT ck_delivery_line_cartons CHECK (cartons > 0)
);
COMMENT ON TABLE supply.delivery_line IS
'One item on a delivery, in cartons. Saving the line puts cartons x units_per_carton units on the store shelf immediately (trigger).';

-- A delivery is on the shelf as soon as it is recorded: translate the
-- docket into the store system's terms and call its receiving interface.
CREATE FUNCTION supply.apply_delivery_line() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_store_no  text;
    v_barcode   text;
    v_units     integer;
    v_at        timestamptz;
BEGIN
    SELECT l.ship_to_store, d.delivered_at_utc AT TIME ZONE 'UTC'
      INTO v_store_no, v_at
      FROM supply.delivery d
      JOIN supply.location l ON l.location_code = d.location_code
     WHERE d.delivery_no = NEW.delivery_no;

    SELECT right(i.gtin14, 13), NEW.cartons * i.units_per_carton
      INTO v_barcode, v_units
      FROM supply.item i WHERE i.supplier_sku = NEW.supplier_sku;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown supplier SKU %', NEW.supplier_sku;
    END IF;

    PERFORM store_ops.receive_goods(v_store_no, v_barcode, v_units, v_at);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_delivery_line_to_store
BEFORE INSERT ON supply.delivery_line
FOR EACH ROW EXECUTE FUNCTION supply.apply_delivery_line();

-- Record one delivery docket with one or more items.
-- Example: SELECT supply.record_delivery('NSW-CHATS', 'Pawfect Foods', ARRAY['PF-DOG-ADT-3K'], ARRAY[5]);
CREATE FUNCTION supply.record_delivery(
    p_location_code     text,
    p_supplier_name     text,
    p_supplier_skus     text[],
    p_cartons           integer[],
    p_delivered_at_utc  timestamp DEFAULT (now() AT TIME ZONE 'UTC')
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_delivery_no bigint;
BEGIN
    IF coalesce(array_length(p_supplier_skus, 1), 0) = 0
       OR array_length(p_supplier_skus, 1) <> coalesce(array_length(p_cartons, 1), 0) THEN
        RAISE EXCEPTION 'Give one carton count per supplier SKU';
    END IF;

    INSERT INTO supply.delivery (location_code, supplier_name, delivered_at_utc)
    VALUES (p_location_code, p_supplier_name, p_delivered_at_utc)
    RETURNING delivery_no INTO v_delivery_no;

    INSERT INTO supply.delivery_line (delivery_no, line_no, supplier_sku, cartons)
    SELECT v_delivery_no, i.n, i.sku, i.cartons
      FROM unnest(p_supplier_skus, p_cartons) WITH ORDINALITY AS i (sku, cartons, n)
     ORDER BY i.n;

    RETURN v_delivery_no;
END;
$$;
