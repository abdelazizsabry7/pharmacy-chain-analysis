-- ============================================================================
-- PHARMACY CHAIN SALES AND INVENTORY ANALYSIS
-- MySQL 8.0+
-- ============================================================================

CREATE DATABASE IF NOT EXISTS pharmacy_chain_analysis;
USE pharmacy_chain_analysis;


-- ============================================================================
-- SECTION 1: RAW STAGING LAYER
-- Create staging tables before importing the CSV files.
-- Text data types preserve blank and malformed values for SQL-based cleaning.
-- ============================================================================

CREATE TABLE IF NOT EXISTS stg_customers (
    customer_id VARCHAR(50),
    customer_name VARCHAR(150),
    email VARCHAR(200),
    gender VARCHAR(50),
    age VARCHAR(20),
    store_location VARCHAR(150),
    registration_date VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS stg_products (
    product_id VARCHAR(50),
    product_name VARCHAR(150),
    category VARCHAR(100),
    cost_price VARCHAR(30),
    retail_price VARCHAR(30)
);

CREATE TABLE IF NOT EXISTS stg_inventory (
    product_id VARCHAR(50),
    current_stock VARCHAR(30),
    reorder_level VARCHAR(30),
    safety_stock VARCHAR(30),
    lead_time_days VARCHAR(30),
    avg_daily_sales VARCHAR(30),
    cost_price VARCHAR(30)
);

CREATE TABLE IF NOT EXISTS stg_transactions (
    transaction_id VARCHAR(50),
    transaction_date VARCHAR(50),
    customer_id VARCHAR(50),
    product_id VARCHAR(50),
    quantity VARCHAR(30),
    unit_price VARCHAR(30),
    store_location VARCHAR(150),
    is_holiday VARCHAR(20)
);

-- Import the four CSV files into their matching staging tables before continuing.


-- ============================================================================
-- SECTION 2: DATA PROFILING
-- Inspect row counts, missing values, duplicates, outliers, and relationships.
-- ============================================================================

-- STAGE 1: Verify the number of imported rows.
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM stg_customers
UNION ALL SELECT 'products', COUNT(*) FROM stg_products
UNION ALL SELECT 'inventory', COUNT(*) FROM stg_inventory
UNION ALL SELECT 'transactions', COUNT(*) FROM stg_transactions;


-- STAGE 2: Check missing values in the customers table.
SELECT
    SUM(customer_id IS NULL OR TRIM(customer_id) = '') AS missing_customer_id,
    SUM(customer_name IS NULL OR TRIM(customer_name) = '') AS missing_customer_name,
    SUM(email IS NULL OR TRIM(email) = '') AS missing_email,
    SUM(gender IS NULL OR TRIM(gender) = '') AS missing_gender,
    SUM(age IS NULL OR TRIM(age) = '') AS missing_age,
    SUM(store_location IS NULL OR TRIM(store_location) = '') AS missing_store_location,
    SUM(registration_date IS NULL OR TRIM(registration_date) = '') AS missing_registration_date
FROM stg_customers;


-- STAGE 3: Check missing values in the transactions table.
SELECT
    SUM(transaction_id IS NULL OR TRIM(transaction_id) = '') AS missing_transaction_id,
    SUM(transaction_date IS NULL OR TRIM(transaction_date) = '') AS missing_transaction_date,
    SUM(customer_id IS NULL OR TRIM(customer_id) = '') AS missing_customer_id,
    SUM(product_id IS NULL OR TRIM(product_id) = '') AS missing_product_id,
    SUM(quantity IS NULL OR TRIM(quantity) = '') AS missing_quantity,
    SUM(unit_price IS NULL OR TRIM(unit_price) = '') AS missing_unit_price,
    SUM(store_location IS NULL OR TRIM(store_location) = '') AS missing_store_location,
    SUM(is_holiday IS NULL OR TRIM(is_holiday) = '') AS missing_holiday_status
FROM stg_transactions;


-- STAGE 4: Count duplicated transaction IDs and extra rows.
SELECT
    COUNT(*) AS duplicated_transaction_ids,
    SUM(repeated_count - 1) AS extra_rows
FROM (
    SELECT transaction_id, COUNT(*) AS repeated_count
    FROM stg_transactions
    GROUP BY transaction_id
    HAVING COUNT(*) > 1
) AS duplicates;


-- STAGE 5: Display examples of duplicated transaction IDs.
SELECT transaction_id, COUNT(*) AS repeated_count
FROM stg_transactions
GROUP BY transaction_id
HAVING COUNT(*) > 1
ORDER BY repeated_count DESC
LIMIT 20;


-- STAGE 6: Examine the transaction quantity distribution and large outliers.
SELECT
    MIN(CAST(quantity AS DECIMAL(10,2))) AS minimum_quantity,
    MAX(CAST(quantity AS DECIMAL(10,2))) AS maximum_quantity,
    ROUND(AVG(CAST(quantity AS DECIMAL(10,2))), 2) AS average_quantity,
    SUM(CAST(quantity AS DECIMAL(10,2)) > 10) AS quantities_above_10
FROM stg_transactions
WHERE quantity IS NOT NULL
  AND TRIM(quantity) <> ''
  AND TRIM(quantity) REGEXP '^[0-9]+([.][0-9]+)?$';


-- STAGE 7: Find nonblank transaction product IDs missing from the product master.
SELECT COUNT(*) AS invalid_product_references
FROM stg_transactions AS t
LEFT JOIN stg_products AS p ON TRIM(t.product_id) = TRIM(p.product_id)
WHERE p.product_id IS NULL
  AND t.product_id IS NOT NULL
  AND TRIM(t.product_id) <> '';


-- STAGE 8: Find nonblank transaction customer IDs missing from the customer master.
SELECT COUNT(*) AS invalid_customer_references
FROM stg_transactions AS t
LEFT JOIN stg_customers AS c ON TRIM(t.customer_id) = TRIM(c.customer_id)
WHERE c.customer_id IS NULL
  AND t.customer_id IS NOT NULL
  AND TRIM(t.customer_id) <> '';


-- STAGE 9: Separate exact duplicate IDs from conflicting duplicate IDs.
WITH duplicate_analysis AS (
    SELECT
        transaction_id,
        COUNT(*) AS row_count,
        COUNT(DISTINCT CONCAT_WS('|',
            COALESCE(transaction_date, '<NULL>'),
            COALESCE(customer_id, '<NULL>'),
            COALESCE(product_id, '<NULL>'),
            COALESCE(quantity, '<NULL>'),
            COALESCE(unit_price, '<NULL>'),
            COALESCE(store_location, '<NULL>'),
            COALESCE(is_holiday, '<NULL>')
        )) AS distinct_versions
    FROM stg_transactions
    GROUP BY transaction_id
    HAVING COUNT(*) > 1
)
SELECT
    SUM(distinct_versions = 1) AS exact_duplicate_ids,
    SUM(distinct_versions > 1) AS conflicting_duplicate_ids,
    COUNT(*) AS total_duplicated_ids
FROM duplicate_analysis;


-- STAGE 10: Display every raw row belonging to a conflicting transaction ID.
WITH conflicting_ids AS (
    SELECT transaction_id
    FROM stg_transactions
    GROUP BY transaction_id
    HAVING COUNT(*) > 1
       AND COUNT(DISTINCT CONCAT_WS('|',
            COALESCE(transaction_date, '<NULL>'),
            COALESCE(customer_id, '<NULL>'),
            COALESCE(product_id, '<NULL>'),
            COALESCE(quantity, '<NULL>'),
            COALESCE(unit_price, '<NULL>'),
            COALESCE(store_location, '<NULL>'),
            COALESCE(is_holiday, '<NULL>')
       )) > 1
)
SELECT t.*
FROM stg_transactions AS t
INNER JOIN conflicting_ids AS c ON t.transaction_id = c.transaction_id
ORDER BY t.transaction_id, t.transaction_date;


-- ============================================================================
-- SECTION 3: DATA CLEANING AND REJECTION LAYER
-- Preserve raw records, assign row-level IDs, classify quality issues,
-- and quarantine rejected transactions instead of deleting them.
-- ============================================================================

-- STAGE 11: Add a staging row identifier only when it does not already exist.
SET @staging_id_exists := (
    SELECT COUNT(*)
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'stg_transactions'
      AND column_name = 'staging_row_id'
);

SET @add_staging_id_sql := IF(
    @staging_id_exists = 0,
    'ALTER TABLE stg_transactions ADD COLUMN staging_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST',
    'SELECT ''staging_row_id already exists'' AS status_message'
);

PREPARE add_staging_id_statement FROM @add_staging_id_sql;
EXECUTE add_staging_id_statement;
DEALLOCATE PREPARE add_staging_id_statement;


-- STAGE 12: Create a reusable view that classifies and ranks duplicate rows.
CREATE OR REPLACE VIEW vw_transaction_quality AS
WITH duplicate_analysis AS (
    SELECT
        transaction_id,
        COUNT(*) AS row_count,
        COUNT(DISTINCT CONCAT_WS('|',
            COALESCE(transaction_date, '<NULL>'),
            COALESCE(customer_id, '<NULL>'),
            COALESCE(product_id, '<NULL>'),
            COALESCE(quantity, '<NULL>'),
            COALESCE(unit_price, '<NULL>'),
            COALESCE(store_location, '<NULL>'),
            COALESCE(is_holiday, '<NULL>')
        )) AS distinct_versions
    FROM stg_transactions
    GROUP BY transaction_id
)
SELECT
    t.*,
    d.row_count,
    d.distinct_versions,
    ROW_NUMBER() OVER (
        PARTITION BY t.transaction_id
        ORDER BY t.staging_row_id
    ) AS duplicate_rank
FROM stg_transactions AS t
INNER JOIN duplicate_analysis AS d ON t.transaction_id = d.transaction_id;


-- STAGE 13: Create a quarantine table containing invalid rows and reasons.
DROP TABLE IF EXISTS rejected_transactions;

CREATE TABLE rejected_transactions AS
SELECT
    staging_row_id,
    transaction_id,
    transaction_date,
    customer_id,
    product_id,
    quantity,
    unit_price,
    store_location,
    is_holiday,
    CONCAT_WS('; ',
        CASE WHEN distinct_versions > 1
             THEN 'Conflicting duplicate transaction ID' END,
        CASE WHEN row_count > 1 AND distinct_versions = 1 AND duplicate_rank > 1
             THEN 'Exact duplicate row' END,
        CASE WHEN transaction_date IS NULL OR TRIM(transaction_date) = ''
             THEN 'Missing transaction date' END,
        CASE WHEN customer_id IS NULL OR TRIM(customer_id) = ''
             THEN 'Missing customer ID' END,
        CASE WHEN product_id IS NULL OR TRIM(product_id) = ''
             THEN 'Missing product ID' END,
        CASE WHEN quantity IS NULL OR TRIM(quantity) = ''
             THEN 'Missing quantity' END,
        CASE WHEN quantity IS NOT NULL AND TRIM(quantity) <> ''
                  AND TRIM(quantity) NOT REGEXP '^[0-9]+([.][0-9]+)?$'
             THEN 'Invalid quantity format' END,
        CASE WHEN TRIM(quantity) REGEXP '^[0-9]+([.][0-9]+)?$'
                  AND CAST(quantity AS DECIMAL(10,2)) NOT BETWEEN 1 AND 10
             THEN 'Quantity outside accepted range' END,
        CASE WHEN unit_price IS NULL OR TRIM(unit_price) = ''
             THEN 'Missing unit price' END,
        CASE WHEN unit_price IS NOT NULL AND TRIM(unit_price) <> ''
                  AND TRIM(unit_price) NOT REGEXP '^[0-9]+([.][0-9]+)?$'
             THEN 'Invalid unit price format' END,
        CASE WHEN TRIM(unit_price) REGEXP '^[0-9]+([.][0-9]+)?$'
                  AND CAST(unit_price AS DECIMAL(10,2)) <= 0
             THEN 'Non-positive unit price' END
    ) AS rejection_reason
FROM vw_transaction_quality
WHERE distinct_versions > 1
   OR (row_count > 1 AND distinct_versions = 1 AND duplicate_rank > 1)
   OR transaction_date IS NULL OR TRIM(transaction_date) = ''
   OR customer_id IS NULL OR TRIM(customer_id) = ''
   OR product_id IS NULL OR TRIM(product_id) = ''
   OR quantity IS NULL OR TRIM(quantity) = ''
   OR TRIM(quantity) NOT REGEXP '^[0-9]+([.][0-9]+)?$'
   OR (TRIM(quantity) REGEXP '^[0-9]+([.][0-9]+)?$'
       AND CAST(quantity AS DECIMAL(10,2)) NOT BETWEEN 1 AND 10)
   OR unit_price IS NULL OR TRIM(unit_price) = ''
   OR TRIM(unit_price) NOT REGEXP '^[0-9]+([.][0-9]+)?$'
   OR (TRIM(unit_price) REGEXP '^[0-9]+([.][0-9]+)?$'
       AND CAST(unit_price AS DECIMAL(10,2)) <= 0);

ALTER TABLE rejected_transactions
    ADD CONSTRAINT pk_rejected_transactions PRIMARY KEY (staging_row_id);


-- STAGE 14: Reconcile raw rows with rejected and potentially clean rows.
SELECT
    (SELECT COUNT(*) FROM stg_transactions) AS raw_rows,
    (SELECT COUNT(*) FROM rejected_transactions) AS rejected_rows,
    (SELECT COUNT(*) FROM stg_transactions)
      - (SELECT COUNT(*) FROM rejected_transactions) AS remaining_clean_rows;


-- ============================================================================
-- SECTION 4: FINAL ANALYTICAL DATA MODEL
-- Create normalized store, customer, product, inventory, and transaction tables.
-- Convert raw text into validated analytical data types and enforce constraints.
-- ============================================================================

-- STAGE 15: Remove previous final tables in foreign-key-safe order.
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS inventory;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS stores;


-- STAGE 16: Create and load the store dimension.
CREATE TABLE stores (
    store_id TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    store_location VARCHAR(150) NOT NULL UNIQUE
);

INSERT INTO stores (store_location)
SELECT DISTINCT TRIM(store_location)
FROM (
    SELECT store_location FROM stg_customers
    UNION
    SELECT store_location FROM stg_transactions
) AS store_names
WHERE store_location IS NOT NULL
  AND TRIM(store_location) <> '';


-- STAGE 17: Create and load the customer dimension.
-- Missing gender becomes Unknown; missing age remains NULL.
CREATE TABLE customers (
    customer_id VARCHAR(20) PRIMARY KEY,
    customer_name VARCHAR(150) NOT NULL,
    email VARCHAR(200) NOT NULL,
    gender VARCHAR(20) NOT NULL,
    age TINYINT UNSIGNED NULL,
    store_id TINYINT UNSIGNED NOT NULL,
    registration_date DATE NOT NULL,
    CONSTRAINT fk_customers_store FOREIGN KEY (store_id) REFERENCES stores (store_id),
    CONSTRAINT chk_customer_age CHECK (age IS NULL OR age BETWEEN 18 AND 100)
);

INSERT INTO customers (
    customer_id, customer_name, email, gender, age, store_id, registration_date
)
SELECT
    TRIM(c.customer_id),
    TRIM(c.customer_name),
    LOWER(TRIM(c.email)),
    COALESCE(NULLIF(TRIM(c.gender), ''), 'Unknown'),
    CAST(CAST(NULLIF(TRIM(c.age), '') AS DECIMAL(5,1)) AS UNSIGNED),
    s.store_id,
    STR_TO_DATE(TRIM(c.registration_date), '%Y-%m-%d')
FROM stg_customers AS c
INNER JOIN stores AS s ON TRIM(c.store_location) = s.store_location;


-- STAGE 18: Create and load the product dimension.
CREATE TABLE products (
    product_id VARCHAR(20) PRIMARY KEY,
    product_name VARCHAR(150) NOT NULL,
    category VARCHAR(100) NOT NULL,
    cost_price DECIMAL(10,2) NOT NULL,
    retail_price DECIMAL(10,2) NOT NULL,
    CONSTRAINT chk_product_cost CHECK (cost_price > 0),
    CONSTRAINT chk_product_price CHECK (retail_price > 0)
);

INSERT INTO products (product_id, product_name, category, cost_price, retail_price)
SELECT
    TRIM(product_id),
    TRIM(product_name),
    TRIM(category),
    CAST(cost_price AS DECIMAL(10,2)),
    CAST(retail_price AS DECIMAL(10,2))
FROM stg_products;


-- STAGE 19: Create and load the inventory table.
-- Cost price is stored only in products to avoid duplicating the same attribute.
CREATE TABLE inventory (
    product_id VARCHAR(20) PRIMARY KEY,
    current_stock INT UNSIGNED NOT NULL,
    reorder_level INT UNSIGNED NOT NULL,
    safety_stock INT UNSIGNED NOT NULL,
    lead_time_days SMALLINT UNSIGNED NOT NULL,
    avg_daily_sales DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_inventory_product FOREIGN KEY (product_id) REFERENCES products (product_id)
);

INSERT INTO inventory (
    product_id, current_stock, reorder_level, safety_stock, lead_time_days, avg_daily_sales
)
SELECT
    TRIM(product_id),
    CAST(current_stock AS UNSIGNED),
    CAST(reorder_level AS UNSIGNED),
    CAST(safety_stock AS UNSIGNED),
    CAST(lead_time_days AS UNSIGNED),
    CAST(avg_daily_sales AS DECIMAL(10,2))
FROM stg_inventory;


-- STAGE 20: Create and load the clean transaction fact table.
-- Sales amount is generated automatically from quantity and actual unit price.
CREATE TABLE transactions (
    transaction_id VARCHAR(20) PRIMARY KEY,
    transaction_date DATETIME NOT NULL,
    customer_id VARCHAR(20) NOT NULL,
    product_id VARCHAR(20) NOT NULL,
    quantity SMALLINT UNSIGNED NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    store_id TINYINT UNSIGNED NOT NULL,
    is_holiday BOOLEAN NOT NULL,
    sales_amount DECIMAL(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    CONSTRAINT fk_transactions_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id),
    CONSTRAINT fk_transactions_product FOREIGN KEY (product_id) REFERENCES products (product_id),
    CONSTRAINT fk_transactions_store FOREIGN KEY (store_id) REFERENCES stores (store_id),
    CONSTRAINT chk_transaction_quantity CHECK (quantity BETWEEN 1 AND 10),
    CONSTRAINT chk_transaction_price CHECK (unit_price > 0)
);

INSERT INTO transactions (
    transaction_id, transaction_date, customer_id, product_id,
    quantity, unit_price, store_id, is_holiday
)
SELECT
    TRIM(q.transaction_id),
    STR_TO_DATE(TRIM(q.transaction_date), '%Y-%m-%d %H:%i:%s'),
    TRIM(q.customer_id),
    TRIM(q.product_id),
    CAST(CAST(q.quantity AS DECIMAL(10,2)) AS UNSIGNED),
    CAST(q.unit_price AS DECIMAL(10,2)),
    s.store_id,
    CASE WHEN UPPER(TRIM(q.is_holiday)) = 'YES' THEN TRUE ELSE FALSE END
FROM vw_transaction_quality AS q
INNER JOIN stores AS s ON TRIM(q.store_location) = s.store_location
LEFT JOIN rejected_transactions AS r ON q.staging_row_id = r.staging_row_id
WHERE r.staging_row_id IS NULL;


-- ============================================================================
-- SECTION 5: FINAL DATA VALIDATION
-- Confirm counts, reconciliation, uniqueness, completeness, ranges, and keys.
-- ============================================================================

-- STAGE 21: Verify final table row counts.
SELECT 'stores' AS table_name, COUNT(*) AS row_count FROM stores
UNION ALL SELECT 'customers', COUNT(*) FROM customers
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'inventory', COUNT(*) FROM inventory
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions
UNION ALL SELECT 'rejected_transactions', COUNT(*) FROM rejected_transactions;


-- STAGE 22: Confirm that every raw transaction is accepted or rejected.
SELECT
    raw_rows,
    clean_rows,
    rejected_rows,
    clean_rows + rejected_rows AS accounted_rows,
    raw_rows - (clean_rows + rejected_rows) AS row_difference
FROM (
    SELECT
        (SELECT COUNT(*) FROM stg_transactions) AS raw_rows,
        (SELECT COUNT(*) FROM transactions) AS clean_rows,
        (SELECT COUNT(*) FROM rejected_transactions) AS rejected_rows
) AS reconciliation;


-- STAGE 23: Verify transaction ID uniqueness.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT transaction_id) AS unique_transaction_ids,
    COUNT(*) - COUNT(DISTINCT transaction_id) AS duplicated_rows
FROM transactions;


-- STAGE 24: Verify that critical transaction fields are complete.
SELECT
    SUM(transaction_id IS NULL) AS missing_transaction_id,
    SUM(transaction_date IS NULL) AS missing_transaction_date,
    SUM(customer_id IS NULL) AS missing_customer_id,
    SUM(product_id IS NULL) AS missing_product_id,
    SUM(quantity IS NULL) AS missing_quantity,
    SUM(unit_price IS NULL) AS missing_unit_price,
    SUM(store_id IS NULL) AS missing_store_id
FROM transactions;


-- STAGE 25: Validate quantity, price, and generated sales amount ranges.
SELECT
    MIN(quantity) AS minimum_quantity,
    MAX(quantity) AS maximum_quantity,
    MIN(unit_price) AS minimum_unit_price,
    MAX(unit_price) AS maximum_unit_price,
    MIN(sales_amount) AS minimum_sales_amount,
    MAX(sales_amount) AS maximum_sales_amount,
    SUM(quantity NOT BETWEEN 1 AND 10) AS invalid_quantities,
    SUM(unit_price <= 0) AS invalid_prices,
    SUM(sales_amount <= 0) AS invalid_sales_amounts
FROM transactions;


-- STAGE 26: Verify final referential integrity.
SELECT
    SUM(c.customer_id IS NULL) AS invalid_customer_references,
    SUM(p.product_id IS NULL) AS invalid_product_references,
    SUM(s.store_id IS NULL) AS invalid_store_references
FROM transactions AS t
LEFT JOIN customers AS c ON t.customer_id = c.customer_id
LEFT JOIN products AS p ON t.product_id = p.product_id
LEFT JOIN stores AS s ON t.store_id = s.store_id;


-- ============================================================================
-- SECTION 6: EXPLORATORY DATA ANALYSIS
-- Analyze sales, profit, time trends, stores, customers, pricing, and inventory.
-- ============================================================================

-- STAGE 27: Identify the analysis period and number of distinct sales days.
SELECT
    MIN(DATE(transaction_date)) AS first_sales_date,
    MAX(DATE(transaction_date)) AS last_sales_date,
    COUNT(DISTINCT DATE(transaction_date)) AS distinct_sales_days
FROM transactions;


-- STAGE 28: Calculate the main sales KPIs in one result.
SELECT
    ROUND(SUM(sales_amount), 2) AS total_revenue,
    COUNT(*) AS total_transactions,
    SUM(quantity) AS total_units_sold,
    ROUND(AVG(sales_amount), 2) AS average_transaction_value,
    ROUND(AVG(quantity), 2) AS average_units_per_transaction
FROM transactions;


-- STAGE 29: Calculate overall gross profit and gross margin percentage.
SELECT
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS total_gross_profit,
    ROUND(
        SUM(t.quantity * (t.unit_price - p.cost_price))
        / NULLIF(SUM(t.sales_amount), 0) * 100,
        2
    ) AS gross_margin_percentage
FROM transactions AS t
INNER JOIN products AS p 
	ON t.product_id = p.product_id;


-- STAGE 30: Analyze monthly revenue, transactions, units, and gross profit.
SELECT
    DATE_FORMAT(t.transaction_date, '%Y-%m') AS sales_month,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    COUNT(*) AS total_transactions,
    SUM(t.quantity) AS units_sold,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit
FROM transactions AS t
INNER JOIN products AS p 
	ON t.product_id = p.product_id
GROUP BY DATE_FORMAT(t.transaction_date, '%Y-%m')
ORDER BY sales_month;


-- STAGE 31: Calculate month-over-month revenue growth.
WITH monthly_sales AS (
    SELECT
        DATE_FORMAT(transaction_date, '%Y-%m') AS sales_month,
        SUM(sales_amount) AS total_revenue
    FROM transactions
    GROUP BY DATE_FORMAT(transaction_date, '%Y-%m')
),
monthly_comparison AS (
    SELECT
        sales_month,
        total_revenue,
        LAG(total_revenue) OVER (ORDER BY sales_month) AS previous_month_revenue
    FROM monthly_sales
)
SELECT
    sales_month,
    ROUND(total_revenue, 2) AS total_revenue,
    ROUND(previous_month_revenue, 2) AS previous_month_revenue,
    ROUND(
        (total_revenue - previous_month_revenue)
        / NULLIF(previous_month_revenue, 0) * 100,
        2
    ) AS monthly_growth_percentage
FROM monthly_comparison
ORDER BY sales_month;


-- STAGE 32: Rank months independently by revenue, gross_profit, and units sold.
WITH monthly_kpis AS (
    SELECT
        DATE_FORMAT(t.transaction_date, '%Y-%m') AS sales_month,
        SUM(t.sales_amount) AS total_revenue,
        SUM(t.quantity) AS units_sold,
        SUM(t.quantity * (t.unit_price - p.cost_price)) AS gross_profit
    FROM transactions AS t
    INNER JOIN products AS p 
		ON t.product_id = p.product_id
    GROUP BY DATE_FORMAT(t.transaction_date, '%Y-%m')
)
SELECT
    sales_month,
    ROUND(total_revenue, 2) AS total_revenue,
    ROUND(gross_profit, 2) AS gross_profit,
    units_sold,
    RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank,
    RANK() OVER (ORDER BY gross_profit DESC) AS profit_rank,
    RANK() OVER (ORDER BY units_sold DESC) AS units_rank
FROM monthly_kpis
ORDER BY revenue_rank;


-- STAGE 33: Analyze sales performance by weekday.
SELECT
    DAYNAME(transaction_date) AS weekday,
    ROUND(SUM(sales_amount), 2) AS total_revenue,
    COUNT(*) AS transaction_count,
    ROUND(AVG(sales_amount), 2) AS average_transaction_value
FROM transactions
GROUP BY DAYNAME(transaction_date)
ORDER BY total_revenue DESC;


-- STAGE 34: Compare store revenue, profit, transactions, units, and ticket size.
SELECT
    s.store_id,
    s.store_location,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit,
    COUNT(*) AS transaction_count,
    SUM(t.quantity) AS units_sold,
    ROUND(AVG(t.sales_amount), 2) AS average_transaction_value
FROM transactions AS t
INNER JOIN stores AS s 
	ON t.store_id = s.store_id
INNER JOIN products AS p 
	ON t.product_id = p.product_id
GROUP BY s.store_id, s.store_location
ORDER BY total_revenue DESC;


-- STAGE 35: Rank stores independently by revenue and gross profit.
WITH store_kpis AS (
    SELECT
        s.store_id,
        s.store_location,
        SUM(t.sales_amount) AS total_revenue,
        SUM(t.quantity * (t.unit_price - p.cost_price)) AS gross_profit
    FROM transactions AS t
    INNER JOIN stores AS s ON t.store_id = s.store_id
    INNER JOIN products AS p ON t.product_id = p.product_id
    GROUP BY s.store_id, s.store_location
)
SELECT
    store_id,
    store_location,
    ROUND(total_revenue, 2) AS total_revenue,
    ROUND(gross_profit, 2) AS gross_profit,
    RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank,
    RANK() OVER (ORDER BY gross_profit DESC) AS profit_rank
FROM store_kpis;


-- STAGE 36: Identify the highest-revenue category in each store.
WITH store_category_sales AS (
    SELECT
        s.store_id,
        s.store_location,
        p.category,
        SUM(t.sales_amount) AS total_revenue
    FROM transactions AS t
    INNER JOIN stores AS s 
		ON t.store_id = s.store_id
    INNER JOIN products AS p 
		ON t.product_id = p.product_id
    GROUP BY s.store_id, s.store_location, p.category
),
ranked_categories AS (
    SELECT
        *,
        RANK() OVER (PARTITION BY store_id ORDER BY total_revenue DESC) AS category_rank
    FROM store_category_sales
)
SELECT
    store_id,
    store_location,
    category,
    ROUND(total_revenue, 2) AS total_revenue
FROM ranked_categories
WHERE category_rank = 1;


-- STAGE 37: Analyze product category performance.
SELECT
    p.category,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit,
    SUM(t.quantity) AS units_sold,
    COUNT(*) AS transaction_count,
    ROUND(
        SUM(t.quantity * (t.unit_price - p.cost_price))
        / NULLIF(SUM(t.sales_amount), 0) * 100,
        2
    ) AS gross_margin_percentage
FROM transactions AS t
INNER JOIN products AS p 
	ON t.product_id = p.product_id
GROUP BY p.category
ORDER BY total_revenue DESC;


-- STAGE 38: Identify the top 10 products by revenue.
SELECT
    p.product_id,
    p.product_name,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit,
    SUM(t.quantity) AS units_sold,
    COUNT(*) AS transaction_count
FROM transactions AS t
INNER JOIN products AS p 
	ON t.product_id = p.product_id
GROUP BY p.product_id, p.product_name
ORDER BY total_revenue DESC
LIMIT 10;


-- STAGE 39: Identify the bottom 10 products by revenue.
SELECT
    p.product_id,
    p.product_name,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit,
    SUM(t.quantity) AS units_sold,
    COUNT(*) AS transaction_count
FROM transactions AS t
INNER JOIN products AS p 
	ON t.product_id = p.product_id
GROUP BY p.product_id, p.product_name
ORDER BY total_revenue ASC
LIMIT 10;


-- STAGE 40: Rank products by gross profit and calculate gross margin.
WITH product_kpis AS (
    SELECT
        p.product_id,
        p.product_name,
        SUM(t.sales_amount) AS total_revenue,
        SUM(t.quantity * (t.unit_price - p.cost_price)) AS gross_profit
    FROM transactions AS t
    INNER JOIN products AS p 
		ON t.product_id = p.product_id
    GROUP BY p.product_id, p.product_name
)
SELECT
    product_id,
    product_name,
    ROUND(gross_profit, 2) AS gross_profit,
    ROUND(gross_profit / NULLIF(total_revenue, 0) * 100, 2) AS gross_margin_percentage,
    RANK() OVER (ORDER BY gross_profit DESC) AS profit_rank
FROM product_kpis
ORDER BY profit_rank;


-- STAGE 41: Identify products frequently sold below listed retail price.
SELECT
    p.product_id,
    p.product_name,
    p.retail_price,
    COUNT(*) AS total_transactions,
    SUM(t.unit_price < p.retail_price) AS below_retail_transactions,
    ROUND(SUM(t.unit_price < p.retail_price) / COUNT(*) * 100, 2)
        AS below_retail_percentage,
    ROUND(AVG(t.unit_price), 2) AS average_selling_price,
    ROUND(AVG(CASE WHEN t.unit_price < p.retail_price
                   THEN p.retail_price - t.unit_price END), 2)
        AS average_price_difference,
    ROUND(SUM(CASE WHEN t.unit_price < p.retail_price
                   THEN (p.retail_price - t.unit_price) * t.quantity
                   ELSE 0 END), 2) AS total_price_difference
FROM transactions AS t
INNER JOIN products AS p 
	ON t.product_id = p.product_id
GROUP BY p.product_id, p.product_name, p.retail_price
HAVING below_retail_transactions > 0
ORDER BY below_retail_percentage DESC, total_price_difference DESC;


-- STAGE 42: Identify the top 10 customers by historical spending.
SELECT
    c.customer_id,
    c.customer_name,
    ROUND(SUM(t.sales_amount), 2) AS total_spending,
    COUNT(*) AS transaction_count,
    SUM(t.quantity) AS units_purchased,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit
FROM transactions AS t
INNER JOIN customers AS c 
	ON t.customer_id = c.customer_id
INNER JOIN products AS p 
	ON t.product_id = p.product_id
GROUP BY c.customer_id, c.customer_name
ORDER BY total_spending DESC
LIMIT 10;


-- STAGE 43: Classify customers by purchase frequency.
WITH customer_frequency AS (
    SELECT customer_id, COUNT(*) AS transaction_count
    FROM transactions
    GROUP BY customer_id
)
SELECT
    CASE
        WHEN transaction_count = 1 THEN 'One Transaction'
        WHEN transaction_count BETWEEN 2 AND 5 THEN 'Two to Five Transactions'
        ELSE 'More Than Five Transactions'
    END AS frequency_group,
    COUNT(*) AS customer_count
FROM customer_frequency
GROUP BY frequency_group
ORDER BY MIN(transaction_count);


-- STAGE 44: Calculate historical customer value metrics.
SELECT
    c.customer_id,
    c.customer_name,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    COUNT(*) AS transaction_count,
    ROUND(AVG(t.sales_amount), 2) AS average_transaction_value,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit
FROM transactions AS t
INNER JOIN customers AS c ON t.customer_id = c.customer_id
INNER JOIN products AS p ON t.product_id = p.product_id
GROUP BY c.customer_id, c.customer_name
ORDER BY total_revenue DESC;


-- STAGE 45: Analyze sales across customer age groups, including unknown ages.
SELECT
    CASE
        WHEN c.age IS NULL THEN 'Unknown'
        WHEN c.age <= 30 THEN '18 to 30 Years'
        WHEN c.age BETWEEN 31 AND 60 THEN '31 to 60 Years'
        ELSE 'Over 60 Years'
    END AS age_group,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    COUNT(*) AS transaction_count,
    SUM(t.quantity) AS units_purchased,
    ROUND(AVG(t.sales_amount), 2) AS average_transaction_value
FROM transactions AS t
INNER JOIN customers AS c ON t.customer_id = c.customer_id
GROUP BY age_group
ORDER BY total_revenue DESC;


-- STAGE 46: Analyze sales across customer gender groups.
SELECT
    c.gender,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    COUNT(*) AS transaction_count,
    SUM(t.quantity) AS units_purchased,
    ROUND(AVG(t.sales_amount), 2) AS average_transaction_value
FROM transactions AS t
INNER JOIN customers AS c ON t.customer_id = c.customer_id
GROUP BY c.gender
ORDER BY total_revenue DESC;


-- STAGE 47: Calculate each customer's registered-store purchase percentage.
SELECT
    c.customer_id,
    c.customer_name,
    COUNT(*) AS total_transactions,
    SUM(t.store_id = c.store_id) AS registered_store_transactions,
    ROUND(SUM(t.store_id = c.store_id) / COUNT(*) * 100, 2)
        AS registered_store_percentage
FROM transactions AS t
INNER JOIN customers AS c ON t.customer_id = c.customer_id
GROUP BY c.customer_id, c.customer_name
ORDER BY registered_store_percentage DESC, total_transactions DESC;


-- STAGE 48: Compare holiday and non-holiday transaction performance.
SELECT
    CASE WHEN is_holiday = 1 THEN 'Holiday' ELSE 'Non-Holiday' END AS day_type,
    ROUND(SUM(sales_amount), 2) AS total_revenue,
    COUNT(*) AS transaction_count,
    SUM(quantity) AS units_sold,
    ROUND(AVG(sales_amount), 2) AS average_transaction_value
FROM transactions
GROUP BY is_holiday;


-- STAGE 49: Compare average daily holiday and non-holiday performance.
SELECT
    CASE WHEN is_holiday = 1 THEN 'Holiday' ELSE 'Non-Holiday' END AS day_type,
    COUNT(DISTINCT DATE(transaction_date)) AS number_of_days,
    ROUND(SUM(sales_amount) / COUNT(DISTINCT DATE(transaction_date)), 2)
        AS average_daily_revenue,
    ROUND(COUNT(*) / COUNT(DISTINCT DATE(transaction_date)), 2)
        AS average_daily_transactions,
    ROUND(SUM(quantity) / COUNT(DISTINCT DATE(transaction_date)), 2)
        AS average_daily_units_sold
FROM transactions
GROUP BY is_holiday;


-- STAGE 50: Identify products at or below their reorder level.
SELECT
    i.product_id,
    p.product_name,
    i.current_stock,
    i.reorder_level
FROM inventory AS i
INNER JOIN products AS p ON i.product_id = p.product_id
WHERE i.current_stock <= i.reorder_level
ORDER BY i.current_stock ASC;


-- STAGE 51: Calculate inventory cover days using unit-based daily demand.
SELECT
    i.product_id,
    p.product_name,
    i.current_stock,
    i.avg_daily_sales,
    ROUND(i.current_stock / NULLIF(i.avg_daily_sales, 0), 2)
        AS inventory_cover_days
FROM inventory AS i
INNER JOIN products AS p ON i.product_id = p.product_id
ORDER BY inventory_cover_days ASC;


-- STAGE 52: Identify products whose cover days are below supplier lead time.
SELECT
    i.product_id,
    p.product_name,
    ROUND(i.current_stock / NULLIF(i.avg_daily_sales, 0), 2)
        AS inventory_cover_days,
    i.lead_time_days
FROM inventory AS i
INNER JOIN products AS p ON i.product_id = p.product_id
WHERE i.current_stock / NULLIF(i.avg_daily_sales, 0) < i.lead_time_days
ORDER BY inventory_cover_days ASC;


-- STAGE 53: Calculate expected unit demand during each product's lead time.
SELECT
    i.product_id,
    p.product_name,
    i.avg_daily_sales,
    i.lead_time_days,
    ROUND(i.avg_daily_sales * i.lead_time_days, 2) AS lead_time_demand,
    i.safety_stock,
    ROUND(i.avg_daily_sales * i.lead_time_days + i.safety_stock, 2)
        AS required_stock,
    i.current_stock
FROM inventory AS i
INNER JOIN products AS p ON i.product_id = p.product_id;


-- STAGE 54: Prioritize products by unit shortage severity.
SELECT
    i.product_id,
    p.product_name,
    i.current_stock,
    ROUND(i.avg_daily_sales * i.lead_time_days + i.safety_stock, 2)
        AS required_stock,
    ROUND(
        i.avg_daily_sales * i.lead_time_days + i.safety_stock - i.current_stock,
        2
    ) AS stock_shortage,
    RANK() OVER (
        ORDER BY i.avg_daily_sales * i.lead_time_days
                 + i.safety_stock - i.current_stock DESC
    ) AS reorder_priority_rank
FROM inventory AS i
INNER JOIN products AS p ON i.product_id = p.product_id
WHERE i.current_stock < i.avg_daily_sales * i.lead_time_days + i.safety_stock
ORDER BY reorder_priority_rank;


-- STAGE 55: Calculate inventory value for each product.
SELECT
    i.product_id,
    p.product_name,
    p.category,
    i.current_stock,
    p.cost_price,
    ROUND(i.current_stock * p.cost_price, 2) AS inventory_value
FROM inventory AS i
INNER JOIN products AS p ON i.product_id = p.product_id
ORDER BY inventory_value DESC;


-- STAGE 56: Calculate total inventory value by product category.
SELECT
    p.category,
    ROUND(SUM(i.current_stock * p.cost_price), 2) AS category_inventory_value
FROM inventory AS i
INNER JOIN products AS p ON i.product_id = p.product_id
GROUP BY p.category
ORDER BY category_inventory_value DESC;


-- STAGE 57: Identify possible overstock using above-average stock and cover days.
WITH inventory_metrics AS (
    SELECT
        i.product_id,
        p.product_name,
        p.category,
        i.current_stock,
        i.reorder_level,
        i.avg_daily_sales,
        ROUND(i.current_stock / NULLIF(i.avg_daily_sales, 0), 2)
            AS inventory_cover_days,
        ROUND(i.current_stock * p.cost_price, 2) AS inventory_value
    FROM inventory AS i
    INNER JOIN products AS p ON i.product_id = p.product_id
)
SELECT
    product_id,
    product_name,
    category,
    current_stock,
    reorder_level,
    avg_daily_sales,
    inventory_cover_days,
    inventory_value
FROM inventory_metrics
WHERE current_stock > reorder_level
  AND current_stock > (SELECT AVG(current_stock) FROM inventory_metrics)
  AND inventory_cover_days > (SELECT AVG(inventory_cover_days) FROM inventory_metrics)
ORDER BY inventory_cover_days DESC, current_stock DESC;


-- STAGE 58: Find the 10 highest-profit products currently at stockout risk.
SELECT
    p.product_id,
    p.product_name,
    ROUND(SUM(t.quantity * (t.unit_price - p.cost_price)), 2) AS gross_profit,
    ROUND(SUM(t.sales_amount), 2) AS total_revenue,
    i.current_stock,
    ROUND(i.avg_daily_sales * i.lead_time_days + i.safety_stock, 2)
        AS required_stock,
    ROUND(
        i.avg_daily_sales * i.lead_time_days + i.safety_stock - i.current_stock,
        2
    ) AS stock_shortage
FROM transactions AS t
INNER JOIN products AS p ON t.product_id = p.product_id
INNER JOIN inventory AS i ON p.product_id = i.product_id
WHERE i.current_stock < i.avg_daily_sales * i.lead_time_days + i.safety_stock
GROUP BY
    p.product_id,
    p.product_name,
    p.cost_price,
    i.current_stock,
    i.avg_daily_sales,
    i.lead_time_days,
    i.safety_stock
ORDER BY gross_profit DESC
LIMIT 10;
