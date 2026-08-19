# Pharmacy Chain Analysis

## Project Overview

This project analyzes the sales, customers, products, and inventory of a pharmacy chain using MySQL. It builds a complete SQL workflow that starts with raw CSV data, profiles and cleans the data, creates a relational analytical model, validates the final tables, and answers business questions related to sales performance, profitability, customer behavior, and inventory risk.

The main objective is to turn raw pharmacy data into reliable business insights that can support decisions such as:

- Which products, categories, and stores generate the most revenue and profit?
- Who are the most valuable and frequent customers?
- How do holiday and non-holiday sales compare?
- Which products are at risk of stockout?
- Which products may be overstocked?
- Which high-profit products should receive the highest reorder priority?

## Tools and Technologies

- MySQL 8.0+
- MySQL Workbench
- SQL concepts used:
  - Common Table Expressions (CTEs)
  - Window functions
  - Aggregate functions
  - Conditional logic with `CASE`
  - Views
  - Primary and foreign keys
  - Data type conversion
  - Data-quality validation

## Dataset Structure

The project uses four source datasets:

- `customers`: customer details, demographics, registration date, and registered store.
- `products`: product names, categories, cost prices, and retail prices.
- `inventory`: current stock, reorder level, safety stock, supplier lead time, and average daily sales.
- `transactions`: transaction date, customer, product, quantity, unit price, store, and holiday status.

Raw data is first imported into the following staging tables:

- `stg_customers`
- `stg_products`
- `stg_inventory`
- `stg_transactions`

After cleaning, the final analytical model contains:

- `stores`
- `customers`
- `products`
- `inventory`
- `transactions`
- `rejected_transactions`

## Project Workflow

### 1. Raw Staging Layer

The four staging tables are created using text-based data types. This preserves blank, malformed, and inconsistent values during import so they can be inspected and handled in SQL instead of being silently lost or converted.

### 2. Data Profiling

The profiling section checks:

- Imported row counts
- Missing customer and transaction fields
- Duplicate transaction IDs
- Exact and conflicting duplicates
- Quantity distribution and possible outliers
- Invalid product references
- Invalid customer references

### 3. Data Cleaning and Rejection Layer

The cleaning process:

- Adds a unique identifier to every raw transaction row
- Classifies duplicate records
- Keeps the first valid version of exact duplicates
- Rejects conflicting duplicates
- Rejects rows with missing or malformed critical fields
- Rejects invalid customer and product references
- Rejects nonpositive quantities and prices
- Stores rejected rows and their rejection reasons in `rejected_transactions`
- Preserves the raw staging data instead of deleting problematic records

### 4. Final Analytical Data Model

Clean dimension and fact tables are created with suitable data types, primary keys, and foreign-key relationships. The final `transactions` table also contains a generated `sales_amount` value based on quantity and unit price.

The final tables must be dropped in child-to-parent order when the model is rebuilt:

```sql
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS inventory;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS stores;
```

### 5. Final Data Validation

The validation section confirms:

- Final table row counts
- Reconciliation of accepted and rejected transactions
- Unique transaction IDs
- Completeness of critical fields
- Valid quantity, price, and sales ranges
- Referential integrity between final tables

### 6. Exploratory Data Analysis

The analysis contains 32 business-focused queries covering:

- Analysis period and distinct sales days
- Revenue, transactions, units sold, and average order value
- Gross profit and gross margin
- Monthly trends and month-over-month revenue growth
- Month, weekday, store, category, and product rankings
- Products sold below their listed retail price
- Top customers and customer purchase frequency
- Customer value, age-group, and gender analysis
- Customer loyalty to the registered store
- Holiday versus non-holiday performance
- Average daily holiday performance
- Reorder-level and stockout-risk analysis
- Inventory cover days and supplier lead-time demand
- Unit shortage and reorder priority
- Product and category inventory value
- Possible overstocked products
- High-profit products currently at stockout risk

## Key Business Metrics

The project calculates several important metrics:

```text
Sales Amount = Quantity × Unit Price

Gross Profit = Quantity × (Unit Price − Cost Price)

Gross Margin % = Gross Profit ÷ Revenue × 100

Inventory Cover Days = Current Stock ÷ Average Daily Sales

Lead-Time Demand = Average Daily Sales × Lead-Time Days

Required Stock = Lead-Time Demand + Safety Stock

Stock Shortage = Required Stock − Current Stock
```

`NULLIF()` is used in division calculations to prevent division-by-zero errors.

## How to Run the Project

1. Open `pharmacy_chain_analysis.sql` in MySQL Workbench.
2. Run Section 1 to create the database and staging tables.
3. Import each CSV file into its matching staging table.
4. Run Section 2 to profile the imported data.
5. Run Sections 3 and 4 to clean the data and build the final model.
6. Run Section 5 to validate the final data.
7. Run Section 6 to generate the analytical results.

Do not run the entire script before importing the CSV files. The staging tables must contain the raw data before the cleaning and loading sections are executed.

When running the prepared-statement block that adds `staging_row_id`, select and execute the complete block from the first `SET` statement through `DEALLOCATE PREPARE`. Executing only the final line can produce an unknown prepared-statement error.

## Repository File

- `pharmacy_chain_analysis.sql`: the complete MySQL workflow, including staging, profiling, cleaning, validation, and exploratory analysis.

## Project Outcome

The project produces a clean and validated relational dataset and a set of decision-oriented SQL analyses. Its final inventory queries connect product profitability with stockout risk, helping the pharmacy chain prioritize replenishment for products with the greatest potential business impact.
