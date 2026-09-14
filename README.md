# olist-ecommerce-profitability-analysis
SQL data cleaning and freight profitability analysis for Olist e-commerce 
# Olist E-Commerce Data Cleaning & Profitability Analysis (SQL)

## 📌 Project Overview
This project performs an end-to-end data cleaning, anomaly detection, and profitability analysis on the public **Olist Brazilian E-Commerce dataset**. The goal of this analysis moves beyond basic reporting to uncover structural profit leakages caused by logistics and freight costs.

---

## 🛠️ Tech Stack & SQL Concepts Used
The entire pipeline was built using **SQL (MySQL syntax)**, focusing on reproducible workflows and statistical rigor:
- **Reproducible Cleaning Views (`CREATE VIEW`):** Avoided destructive operations like `TRUNCATE` or `DELETE`, ensuring the pipeline can be re-run cleanly from raw CSV loads.
- **Advanced Window Functions:** Utilized `ROW_NUMBER()` for deduplication across multi-column keys.
- **Statistical Outlier Detection (IQR Method):** Implemented Interquartile Range ($Q3 + 1.5 \times IQR$) formulas dynamically using CTEs to flag anomalies in delivery times, product dimensions, payment values, and seller order volumes.
- **Data Integrity:** Used `COALESCE` for null-handling and `NULLIF` to prevent division-by-zero errors in ratio calculations.
- **Financial Aggregations:** Multi-table `JOIN` operations linking customers, sellers, order items, and payments to evaluate unit-level economics.

---

## 🔍 Key Business Insights & Findings
1. **Structural Margin Erosion (Freight Leakage):** Logistics costs frequently outpace base product prices on specific category-state combinations. Profit leakage happens exclusively when the freight value exceeds the product price (selling at an item-level loss despite high gross revenue).
2. **Geographic Disparities:** Cross-state shipments show severe margin degradation compared to local fulfillments due to inflated transit costs, turning certain customer states into "Loss States".
3. **Category Vulnerabilities:** Heavy and bulky product categories suffer from extreme freight-to-price ratios, eating up seller commissions and platform margins.

---

## 💡 Strategic Recommendations (Executive Verdict)
- **Shift from Volume Growth to Margin Defense:** Stop chasing vanity order volume in high-freight categories without optimizing basket economics.
- **Decentralize Fulfillment:** Implement hub-and-spoke models or regional dark stores to shorten cross-state shipping distances.
- **Enforce Minimum Basket Sizes:** Introduce order thresholds or shipping surcharges for categories where freight-to-price ratios threaten unit profitability.
