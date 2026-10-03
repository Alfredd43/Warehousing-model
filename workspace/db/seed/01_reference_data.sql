-- =============================================================================
-- seed/01_reference_data.sql
-- Purpose: Master and reference data for the three sources, and the approved
--          code cross-references used by the ETL.
-- Design ref: docs/Architecture_and_Data_Model.md sections 4 and 5.2.
-- Prerequisites: 01-08 applied to an empty database.
--
-- Each source names the same store and product differently:
--
--   Warehouse  Store system (S1)  Delivery system (S2)  Online store (S3)
--   S01        store_no 101       NSW-PARRA             CP-PARRAMATTA
--   P001       9300601001019      PF-DOG-ADT-3K         WEB-10001
--
-- Product P019 (Crinkle Cat Tunnel) is a new line: it is in the store and
-- delivery catalogues but has NO approved warehouse mapping yet and is not
-- sold online. Moving its stock exercises the ETL's rejection path
-- (see docs/demo_runbook.md, data quality step).
-- =============================================================================

-- One authoring table so each product's codes sit on one line. Not part of
-- the design; dropped at the end of this file.
CREATE TEMP TABLE seed_product (
    product_code      text,
    barcode           text,
    description       text,
    category          text,
    price             numeric(10,2),
    supplier_sku      text,
    units_per_carton  integer,
    web_sku           text,
    web_title         text
);
INSERT INTO seed_product VALUES
    ('P001', '9300601001019', 'Adult Dry Dog Food Chicken 3kg',    'Food',         39.95, 'PF-DOG-ADT-3K',  4, 'WEB-10001', 'Chicken Adult Dry Dog Food (3 kg)'),
    ('P002', '9300601001026', 'Puppy Dry Dog Food Lamb 3kg',       'Food',         42.95, 'PF-DOG-PUP-3K',  4, 'WEB-10002', 'Lamb Puppy Dry Food (3 kg)'),
    ('P003', '9300601001033', 'Wet Cat Food Tuna 12-pack',         'Food',         18.50, 'PF-CAT-TUNA-12', 6, 'WEB-10003', 'Tuna Wet Cat Food, 12 x 85 g'),
    ('P004', '9300601001040', 'Indoor Dry Cat Food 2kg',           'Food',         29.95, 'PF-CAT-IND-2K',  6, 'WEB-10004', 'Indoor Cat Dry Food (2 kg)'),
    ('P005', '9300601001057', 'Grain-Free Dog Treats 500g',        'Treats',       14.95, 'PF-TRT-GF-500', 12, 'WEB-10005', 'Grain-Free Dog Treats (500 g)'),
    ('P006', '9300601001064', 'Dental Chew Sticks 28-pack',        'Treats',       24.95, 'PF-TRT-DEN-28',  6, 'WEB-10006', 'Dental Chews for Dogs, 28 pack'),
    ('P007', '9300601001071', 'Catnip Mouse Toy 3-pack',           'Toys',          9.95, 'PP-CAT-MSE-3',  12, 'WEB-10007', 'Catnip Mice (3 pack)'),
    ('P008', '9300601001088', 'Rope Tug Toy Large',                'Toys',         16.95, 'PP-DOG-ROPE-L',  4, 'WEB-10008', 'Large Rope Tug Toy'),
    ('P009', '9300601001095', 'Squeaky Plush Duck',                'Toys',         12.95, 'PP-DOG-DUCK',    6, 'WEB-10009', 'Squeaky Plush Duck Dog Toy'),
    ('P010', '9300601001101', 'Interactive Feather Wand',          'Toys',         11.50, 'PP-CAT-WAND',    6, 'WEB-10010', 'Feather Wand Cat Teaser'),
    ('P011', '9300601001118', 'Adjustable Nylon Dog Collar M',     'Accessories',  19.95, 'PG-COL-NYL-M',   6, 'WEB-10011', 'Nylon Dog Collar - Medium'),
    ('P012', '9300601001125', 'Retractable Dog Lead 5m',           'Accessories',  34.95, 'PG-LEAD-RET-5',  4, 'WEB-10012', 'Retractable Lead 5 m'),
    ('P013', '9300601001132', 'Orthopaedic Dog Bed Large',         'Bedding',     129.00, 'PG-BED-ORTH-L',  1, 'WEB-10013', 'Orthopaedic Dog Bed - Large'),
    ('P014', '9300601001149', 'Clumping Cat Litter 10L',           'Hygiene',      21.95, 'VC-LIT-CLMP-10', 4, 'WEB-10014', 'Clumping Cat Litter 10 L'),
    ('P015', '9300601001156', 'Stainless Steel Pet Bowl 1L',       'Accessories',  12.95, 'PG-BWL-SS-1L',   6, 'WEB-10015', 'Stainless Steel Bowl 1 L'),
    ('P016', '9300601001163', 'Flea and Tick Spot-On Dog 10-25kg', 'Health',       54.95, 'VC-FLEA-DOG-M',  6, 'WEB-10016', 'Flea & Tick Spot-On, Dogs 10-25 kg'),
    ('P017', '9300601001170', 'Cat Scratching Post 80cm',          'Furniture',    69.95, 'PG-SCR-POST-80', 1, 'WEB-10017', 'Cat Scratching Post 80 cm'),
    ('P018', '9300601001187', 'Aquarium Starter Kit 40L',          'Aquatics',    149.00, 'AW-AQ-KIT-40',   1, 'WEB-10018', 'Aquarium Starter Kit 40 L'),
    -- New line, not yet approved for the warehouse, not sold online.
    ('P019', '9300601001194', 'Crinkle Cat Tunnel',                'Toys',         24.95, 'PP-CAT-TUNNEL',  4, NULL,        NULL);

CREATE TEMP TABLE seed_store (
    store_code     text,
    store_no       text,
    store_name     text,
    suburb         text,
    postcode       text,
    location_code  text,
    cp_code        text,
    latitude       numeric(9,6),
    longitude      numeric(9,6)
);
INSERT INTO seed_store VALUES
    ('S01', '101', 'PetHaven Parramatta', 'Parramatta',     '2150', 'NSW-PARRA', 'CP-PARRAMATTA',     -33.815000, 151.001100),
    ('S02', '102', 'PetHaven Bondi',      'Bondi Junction', '2022', 'NSW-BONDI', 'CP-BONDI-JUNCTION', -33.891500, 151.250200),
    ('S03', '103', 'PetHaven Chatswood',  'Chatswood',      '2067', 'NSW-CHATS', 'CP-CHATSWOOD',      -33.796900, 151.180300),
    ('S04', '104', 'PetHaven Newtown',    'Newtown',        '2042', 'NSW-NEWTN', 'CP-NEWTOWN',        -33.898100, 151.174700),
    ('S05', '105', 'PetHaven Penrith',    'Penrith',        '2750', 'NSW-PENRI', 'CP-PENRITH',        -33.750700, 150.687700);


-- ---------------------------------------------------------------------------
-- Source 1: store system
-- ---------------------------------------------------------------------------
INSERT INTO store_ops.store (store_no, store_name, suburb, postcode)
SELECT store_no, store_name, suburb, postcode FROM seed_store;

INSERT INTO store_ops.product (barcode, description, category, shelf_price)
SELECT barcode, description, category, price FROM seed_product;

-- ---------------------------------------------------------------------------
-- Source 2: delivery system
-- ---------------------------------------------------------------------------
INSERT INTO supply.location (location_code, location_name, ship_to_store)
SELECT location_code, store_name || ' (store receiving dock)', store_no FROM seed_store;

INSERT INTO supply.item (supplier_sku, item_description, gtin14, units_per_carton)
SELECT supplier_sku, upper(description), '0' || barcode, units_per_carton FROM seed_product;

-- ---------------------------------------------------------------------------
-- Source 3: online store (website numbers start at 0 until the first sync)
-- ---------------------------------------------------------------------------
INSERT INTO online.product (web_sku, title, web_price, pos_barcode)
SELECT web_sku, web_title, price, barcode FROM seed_product WHERE web_sku IS NOT NULL;

INSERT INTO online.online_stock (web_sku, available_quantity, last_synced_at)
SELECT web_sku, 0, NULL FROM online.product;

INSERT INTO online.collection_point (cp_code, cp_name, latitude, longitude, store_no)
SELECT cp_code, 'Click & Collect - ' || suburb, latitude, longitude, store_no FROM seed_store;

INSERT INTO online.postcode_location (postcode, suburb, latitude, longitude) VALUES
    ('2000', 'Sydney CBD',     -33.868800, 151.209300),
    ('2010', 'Surry Hills',    -33.886100, 151.211100),
    ('2022', 'Bondi Junction', -33.891500, 151.250200),
    ('2026', 'Bondi',          -33.891500, 151.276700),
    ('2031', 'Randwick',       -33.914500, 151.241600),
    ('2042', 'Newtown',        -33.898100, 151.174700),
    ('2065', 'St Leonards',    -33.823000, 151.195000),
    ('2067', 'Chatswood',      -33.796900, 151.180300),
    ('2077', 'Hornsby',        -33.704600, 151.099300),
    ('2100', 'Brookvale',      -33.767000, 151.270000),
    ('2112', 'Ryde',           -33.815000, 151.105000),
    ('2135', 'Strathfield',    -33.879000, 151.083000),
    ('2145', 'Westmead',       -33.807500, 150.987000),
    ('2150', 'Parramatta',     -33.815000, 151.001100),
    ('2155', 'Kellyville',     -33.714000, 150.955000),
    ('2170', 'Liverpool',      -33.920000, 150.923000),
    ('2200', 'Bankstown',      -33.918000, 151.035000),
    ('2750', 'Penrith',        -33.750700, 150.687700),
    ('2760', 'St Marys',       -33.762000, 150.774000),
    ('2770', 'Mount Druitt',   -33.769000, 150.819000);

-- ---------------------------------------------------------------------------
-- ETL: approved cross-references (P019 deliberately left out)
-- ---------------------------------------------------------------------------
INSERT INTO etl.store_xref (source_system, source_code, store_code, approved_by)
SELECT 'STORE',  store_no,      store_code, 'seed' FROM seed_store
UNION ALL
SELECT 'SUPPLY', location_code, store_code, 'seed' FROM seed_store
UNION ALL
SELECT 'ONLINE', cp_code,       store_code, 'seed' FROM seed_store;

INSERT INTO etl.product_xref (source_system, source_code, product_code, approved_by)
SELECT 'STORE',  barcode,      product_code, 'seed' FROM seed_product WHERE product_code <> 'P019'
UNION ALL
SELECT 'SUPPLY', supplier_sku, product_code, 'seed' FROM seed_product WHERE product_code <> 'P019'
UNION ALL
SELECT 'ONLINE', web_sku,      product_code, 'seed' FROM seed_product WHERE web_sku IS NOT NULL;

-- Conformed dimensions from the approved mappings.
SELECT etl.load_dimensions();

DROP TABLE seed_product;
DROP TABLE seed_store;
