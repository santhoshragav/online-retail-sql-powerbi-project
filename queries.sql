-- ================================================================
-- UK Online Retailer — Sales Performance Analysis
-- Full SQL Pipeline: Import -> Clean -> Schema -> RFM -> Analysis
-- ================================================================


-- ================================================================
-- SECTION 1: Database & Staging Table Setup
-- ================================================================

CREATE DATABASE online_retail;
USE online_retail;

-- Raw staging table (populated via MySQL Workbench Import Wizard
-- from the Online Retail II CSV, sourced from Kaggle/UCI)
CREATE TABLE online_retail (
    Invoice     VARCHAR(20),
    StockCode   VARCHAR(20),
    Description VARCHAR(255),
    Quantity    INT,
    InvoiceDate DATETIME,
    Price       DECIMAL(10,2),
    CustomerID  INT,
    Country     VARCHAR(50)
);

-- Data loaded via Workbench Table Data Import Wizard.


-- ================================================================
-- SECTION 2: Data Cleaning & Preparation
-- ================================================================

-- Create a cleaned working table, excluding cancellations, missing
-- customers, and invalid quantity/price rows
CREATE TABLE retail_clean AS
SELECT *
FROM online_retail
WHERE Invoice NOT LIKE 'C%'
  AND CustomerID IS NOT NULL
  AND Quantity > 0
  AND Price > 0;

-- Standardize product descriptions (fix case/whitespace inconsistencies)
UPDATE retail_clean
SET Description = TRIM(UPPER(Description));

-- Fix column data types to match the actual data
ALTER TABLE retail_clean MODIFY Invoice VARCHAR(20);
ALTER TABLE retail_clean MODIFY StockCode VARCHAR(20);
ALTER TABLE retail_clean MODIFY CustomerID INT;
ALTER TABLE retail_clean MODIFY InvoiceDate DATETIME;


-- ================================================================
-- SECTION 3: Schema Design (Normalized Tables)
-- ================================================================

CREATE TABLE customers (
    CustomerID INT PRIMARY KEY,
    Country VARCHAR(50)
);

CREATE TABLE products (
    StockCode VARCHAR(50) PRIMARY KEY,
    Description VARCHAR(100)
);

CREATE TABLE orders (
    Invoice VARCHAR(50) PRIMARY KEY,
    CustomerID INT,
    InvoiceDate DATETIME,
    FOREIGN KEY (CustomerID) REFERENCES customers(CustomerID)
);

-- order_items uses a surrogate key (OrderItemID) rather than a
-- composite key, since the same product can appear on the same
-- invoice more than once at different prices (e.g. tiered pricing)
CREATE TABLE order_items (
    OrderItemID INT AUTO_INCREMENT PRIMARY KEY,
    Invoice VARCHAR(20),
    StockCode VARCHAR(20),
    Quantity INT,
    Price DECIMAL(10,2),
    FOREIGN KEY (Invoice) REFERENCES orders(Invoice),
    FOREIGN KEY (StockCode) REFERENCES products(StockCode)
);


-- ================================================================
-- SECTION 4: Populate Normalized Tables
-- ================================================================

INSERT INTO customers (CustomerID, Country)
SELECT DISTINCT CustomerID, Country
FROM retail_clean
WHERE CustomerID IS NOT NULL;

-- MIN(Description) resolves cases where the same StockCode has more
-- than one description variant even after cleaning
INSERT INTO products (StockCode, Description)
SELECT StockCode, MIN(Description) AS Description
FROM retail_clean
WHERE StockCode IS NOT NULL
GROUP BY StockCode;

INSERT INTO orders (Invoice, CustomerID, InvoiceDate)
SELECT Invoice, CustomerID, InvoiceDate
FROM retail_clean
WHERE CustomerID IS NOT NULL
GROUP BY Invoice;

INSERT INTO order_items (Invoice, StockCode, Quantity, Price)
SELECT Invoice, StockCode, Quantity, Price
FROM retail_clean
WHERE CustomerID IS NOT NULL
  AND Quantity > 0
  AND Price > 0
  AND Invoice NOT LIKE 'C%';


-- ================================================================
-- SECTION 5: RFM Segmentation
-- ================================================================

CREATE TABLE rfm_segments (
    CustomerID INT PRIMARY KEY,
    recency INT,
    frequency INT,
    monetary INT,
    segment_label VARCHAR(50),
    FOREIGN KEY (CustomerID) REFERENCES customers(CustomerID)
);

INSERT INTO rfm_segments (CustomerID, recency, frequency, monetary, segment_label)
SELECT CustomerID, recency, frequency, monetary, segment
FROM (
    SELECT CustomerID, recency, frequency, monetary, rscore, F_Score, M_Score,
        CASE
            WHEN rscore = 5 AND F_Score = 5 AND M_Score = 5 THEN 'CHAMPION CUSTOMER'
            WHEN rscore IN (3,4) AND F_Score IN (3,4) THEN 'loyal customer'
            WHEN rscore <= 2 AND F_Score <= 4 THEN 'at risk'
            WHEN rscore = 5 AND F_Score IN (1,2) THEN 'new customer'
            ELSE 'others'
        END AS segment
    FROM (
        SELECT
            CustomerID,
            DATEDIFF((SELECT MAX(InvoiceDate) FROM retail_clean), MAX(InvoiceDate)) AS recency,
            COUNT(DISTINCT Invoice) AS frequency,
            SUM(Quantity * Price) AS monetary,
            NTILE(5) OVER (ORDER BY DATEDIFF((SELECT MAX(InvoiceDate) FROM retail_clean), MAX(InvoiceDate)) DESC) AS rscore,
            NTILE(5) OVER (ORDER BY COUNT(DISTINCT Invoice) ASC) AS F_Score,
            NTILE(5) OVER (ORDER BY SUM(Quantity * Price) ASC) AS M_Score
        FROM retail_clean
        GROUP BY CustomerID
    ) AS rfm_base
) AS final_rfm;


-- ================================================================
-- SECTION 6: Key Business Queries
-- ================================================================

-- Q: Total revenue (excluding cancellations)
SELECT SUM(Quantity * Price) AS total_revenue
FROM retail_clean;

-- Q: Top 10 products by revenue
SELECT Description AS product, SUM(Quantity * Price) AS total_rev
FROM retail_clean
GROUP BY product
ORDER BY total_rev DESC
LIMIT 10;

-- Q: Top country by revenue, excluding the UK
SELECT Country, SUM(Quantity * Price) AS total_rev
FROM retail_clean
WHERE Country != 'United Kingdom'
GROUP BY Country
ORDER BY total_rev DESC
LIMIT 1;

-- Q: Monthly/daily revenue trend
SELECT DATE_FORMAT(InvoiceDate, '%Y-%m-%d') AS day, SUM(Quantity * Price) AS daily_rev
FROM retail_clean
GROUP BY day
ORDER BY day;

-- Q: Top 10 customers by total spend
SELECT CustomerID, SUM(Quantity * Price) AS total_spent
FROM retail_clean
WHERE CustomerID IS NOT NULL AND Quantity > 0 AND Price > 0 AND Invoice NOT LIKE 'C%'
GROUP BY CustomerID
ORDER BY total_spent DESC
LIMIT 10;

-- Q: What % of total revenue comes from the top 10 customers?
SELECT
    (SELECT SUM(TotalSpend)
     FROM (
        SELECT CustomerID, SUM(Quantity * Price) AS TotalSpend
        FROM retail_clean
        WHERE CustomerID IS NOT NULL AND Quantity > 0 AND Price > 0 AND Invoice NOT LIKE 'C%'
        GROUP BY CustomerID
        ORDER BY TotalSpend DESC
        LIMIT 10
     ) AS Top10) * 100.0 /
    (SELECT SUM(Quantity * Price)
     FROM retail_clean
     WHERE CustomerID IS NOT NULL AND Quantity > 0 AND Price > 0 AND Invoice NOT LIKE 'C%') AS Top10Percentage;

-- Q: Average order value by country
SELECT Country, SUM(Quantity * Price) / COUNT(DISTINCT Invoice) AS AvgOrderValue
FROM retail_clean
WHERE CustomerID IS NOT NULL AND Quantity > 0 AND Price > 0 AND Invoice NOT LIKE 'C%'
GROUP BY Country
ORDER BY AvgOrderValue DESC;

-- Q: One-time vs repeat buyers - % of revenue from each group
SELECT buyertype,
    SUM(totalspend) * 100 / (
        SELECT SUM(Quantity * Price)
        FROM retail_clean
        WHERE CustomerID IS NOT NULL AND Quantity > 0 AND Price > 0 AND Invoice NOT LIKE 'C%'
    ) AS RevenuePercentage
FROM (
    SELECT CustomerID, COUNT(DISTINCT Invoice) AS orders, SUM(Quantity * Price) AS totalspend,
        CASE
            WHEN COUNT(DISTINCT Invoice) = 1 THEN 'one time buyers'
            ELSE 'regular buyers'
        END AS buyertype
    FROM retail_clean
    WHERE CustomerID IS NOT NULL AND Quantity > 0 AND Price > 0 AND Invoice NOT LIKE 'C%'
    GROUP BY CustomerID
) AS CustomerGroups
GROUP BY buyertype;

-- Q: RFM segment distribution
SELECT segment_label, COUNT(*) AS customer_count
FROM rfm_segments
GROUP BY segment_label;
