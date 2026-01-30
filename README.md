# Getting Started with Horizon for Data Governance in Snowflake

## Overview
Horizon is a suite of native Snowflake features that allow users to easily find, understand, and trust data. In this lab you'll learn how Horizon ensures people have reliable and trustworthy data to make confident, data-driven decisions while ensuring observability and security of data assets.

In this expert-led, hands-on lab, you will follow a step-by-step guide utilizing a provided sample database of synthetic customer orders. Using this example data, you will learn how Horizon can monitor and provide visibility into your data within Snowflake.

## Step-by-Step Guide
For prerequisites, environment setup, step-by-step guide and instructions, please refer to the [QuickStart Guide](https://quickstarts.snowflake.com/guide/getting_started_with_horizon_for_data_governance_in_snowflake/index.html?index=..%2F..index#0).

---

## AI Governance Extensions (v2.0)

This lab has been extended to demonstrate AI governance capabilities using Snowflake's latest features.

### What's New

**Governing AI Assets:**
- **Section 4: Semantic View Governance** - Create semantic views for Cortex Analyst where fine-grained access controls are automatically honored

**AI-Assisted Governance:**
- **Section 5: Cortex AI_REDACT** - Protect unstructured PII in customer feedback and text data
- **Section 6: Natural Language Governance** - Query governance metadata using natural language

### Lab 2: AI Classification with Tag Propagation

Lab 2 demonstrates **AI-powered classification** with custom tag mapping:

**Key Features:**
- **Classification Profile with tag_map** - Maps native categories to custom `DATA_CLASSIFICATION` tag
- **Five-tier taxonomy** - PII, RESTRICTED, SENSITIVE, INTERNAL, PUBLIC
- **Tag propagation** - BYOT (Bring Your Own Tags) pattern ensures tags flow to downstream tables
- **Unified masking policy** - Single policy applies to all classification levels via tag
- **Custom classifiers** - Detect domain-specific patterns (credit card types)

**What gets classified:**
- CUSTOMER table (SSN, email, phone, names, addresses)
- CUSTOMER_ORDERS table (ORDER_ID, CUSTOMER_ID, ORDER_TS)

**Result:** Structured columns are automatically tagged and masked based on sensitivity level.

### Lab 5: AI_REDACT for Unstructured Data

Lab 5 demonstrates **Cortex AI_REDACT** for protecting PII in free-form text:

**Key Features:**
- **Add customer feedback column** with embedded PII (names, emails, phones, SSN)
- **AI_REDACT function** - Automatically detects 50+ PII types in text
- **Pre-computed redaction** - Create redacted tables (not expensive views)
- **Tag propagation verification** - Classification tags from Lab 2 flow to new tables
- **Role-based access** - Governors see original, analysts see redacted version
- **ML-ready data** - Safe sentiment analysis on redacted feedback

**Performance notes:**
- Limited to 100 rows for demo performance
- Redaction runs once during table creation (not on every query)
- Secure view switches between pre-computed columns based on role

### Key Demo: Consistent Policy Enforcement

The highlight of this extension demonstrates how existing data governance policies are 
automatically enforced when querying data through AI interfaces:

1. **Create a Semantic View** over governed tables (CUSTOMER, CUSTOMER_ORDERS)
2. **Query via Cortex Analyst** using natural language
3. **Observe policy enforcement** - masking and row access policies apply automatically, 
   regardless of whether data is accessed via SQL or AI

**Test Query:**
```
"Get me the full names and phone number of our ten highest billing customers per state"
```

**Expected Results:**
| Role | State Access | Phone Numbers |
|------|--------------|---------------|
| HRZN_DATA_GOVERNOR | All states | Visible if OPTIN='Y', masked if OPTIN='N' |
| HRZN_DATA_USER | MA only | Visible if OPTIN='Y', masked if OPTIN='N' |

### Execution Order

```
1. 0-lab-Setup.sql                          (ACCOUNTADMIN) - Creates roles, database, AI privileges
2. hol-lab/1-DataEngineer.sql               (HRZN_DATA_ENGINEER) - Creates tables, loads data
3. hol-lab/2-DataGovernor_DataUser.sql      (HRZN_DATA_GOVERNOR) - AI classification + policies
4. hol-lab/3-Data-governor-Admin.sql        (HRZN_IT_ADMIN) - Auditing queries
5. hol-lab/4-Semantic-View-Governance.sql   (HRZN_DATA_GOVERNOR) - Semantic views for Cortex Analyst
6. hol-lab/5-Cortex-AI-Redact.sql           (HRZN_DATA_GOVERNOR) - AI_REDACT for unstructured PII
7. hol-lab/6-Natural-Language-Governance.sql (HRZN_DATA_GOVERNOR) - NL governance queries
```

### Lab Dependencies

- **Lab 2 → Lab 5**: Classification tags from Lab 2 propagate to tables created in Lab 5
- **Lab 1 → Lab 2**: Lab 2 classifies tables created in Lab 1
- **Lab 2 → Lab 4**: Semantic views in Lab 4 respect policies defined in Lab 2

### Testing Semantic Views in Cortex Analyst

1. Navigate to **Projects > Cortex Analyst** in Snowsight
2. Select the `CUSTOMER_ORDER_ANALYTICS` semantic view
3. Switch roles to test policy enforcement:
   - As `HRZN_DATA_GOVERNOR`: See all states, conditional phone masking
   - As `HRZN_DATA_USER`: See MA only, conditional phone masking

---

**Version:** HLab v2.0  
**Contributors:** Ravi Kumar (original), Severin Gassauer (AI extensions)  
**Copyright:** 2026 Snowflake Inc. All rights reserved.
