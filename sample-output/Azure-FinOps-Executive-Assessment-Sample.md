**Save as PDF**

# Azure FinOps Executive Assessment

CloudGenius · Month-to-date cost position, September 2026

Tenant: cloudgenius.caBilling data through 2026-09-19 (UTC)Generated 2026-09-19 18:14 UTC

**Cost Data:**Verified**Subscription Coverage:**Complete**Current Resource Inventory:**Reconciled**Currency:**Validated**Report Completeness:**Complete

[Spend at a glance](#glance)[Cost drivers](#drivers)[Governance](#governance)[Actions](#actions)[Decisions](#decisions)[Detail](#detail)[Calculations](#calculations)[Methodology](#appendix)

**Active** - cost from resources that exist today.

**Historical / Deleted** - cost from resources that no longer exist; expected to stop.

**Unmapped** - charges with no specific resource (purchases, support, adjustments).

## Executive Financial Headline

Azure cost position is currently low. Verified month-to-date spend is 4.5931 CAD, with essentially all recorded cost attributable to networking resources that are no longer deployed. The immediate focus is confirming these charges do not recur and strengthening cost-accountability tagging.

## Spend at a glance

**Amounts in CAD**

MTD Actual Cost

**4.5931 CAD**

Month-to-date, billing currency

Active Spend

**0.0000 CAD**

0% of total - resources that exist today

Historical / Deleted Spend

**4.5931 CAD**

100% of total - resources no longer deployed

Unmapped Spend

**0.0000 CAD**

0% of total - not tied to a resource

Indicative Month-End Run Rate

**Not calculated**

See note below

Active 0%Historical / Deleted 100%Unmapped 0%

**Historical/deleted resources represent 100% of month-to-date spend - most of the cost comes from resources that no longer exist.**

Run rate: Not calculated because historical/deleted resources represent 100% of month-to-date spend.

**Estate**

Enabled Subscriptions

**2**

All assessed

Current ARM Resources

**15**

Independently enumerated live inventory

Current Resources With No MTD Cost

**15**

Deployed but not billing this month

## Primary cost drivers

**vng-cloudgenius-azure Historical / Deleted**

**VPN Gateway**

**4.5326 CAD**

**98.7% of total**

**pip-cloudgenius-azure-vpngw Historical / Deleted**

**Virtual Network**

**0.0605 CAD**

**1.3% of total**

CAD - largest single cost line

**vng-cloudgenius-azure** **Historical / Deleted**
4.5326 CAD · 98.7% of month-to-date spend. Billed mainly under VPN Gateway.

CAD - largest service category

**VPN Gateway**
98.7% of month-to-date spend.

## Key financial and governance consideration

Historical/deleted resources represent 100% of month-to-date spend (4.5931 CAD). Because those resources are no longer deployed the cost is expected to stop; confirm it does not recur in the next billing period. For vng-cloudgenius-azure, the largest of them, Azure confirmed by direct lookup that the resource no longer exists; its last charge is dated 2026-09-19, the latest billing date. That is consistent with removal today or very recently (the latest day is partial), so re-check tomorrow that no new charge appears.

Optimization focus

Review historical/deleted charges first, then assess the highest-cost active workloads for right-sizing and pricing-model opportunities once active spend is material.

## Cost governance readiness

CostCenter tag coverage

**0%**

0 of 15 live resources

Owner tag coverage

**0%**

0 of 15 live resources

Environment tag coverage

**0%**

0 of 15 live resources

Fully tagged

**0%**

0 of 15 carry all required tags

Readiness stage

**Foundational**

Tagging-based indicator

Governance opportunity: introduce CostCenter, Owner, and Environment tagging standards to improve accountability, showback, and future chargeback readiness.

Indicator based on the share of live resources carrying every required tag. Budgets, policy enforcement and anomaly alerting were not assessed. Top-level resources only: 0% fully tagged (0 of 12).

### Tagging recommendations

None of the 15 live resource(s) carries any of the required tags (CostCenter, Owner, and Environment). 3 carry other tags, but none of the required ones. Tags do appear on the bills of resources that have since been deleted, so a tagging standard was applied there but was not carried over to the live estate.

- Start at resource-group level: tag every resource group with the required tags (CostCenter, Owner, and Environment), then use the built-in Azure Policy "Inherit a tag from the resource group" (Modify effect) so resources pick the tags up automatically. This lifts coverage fastest for the least effort.
- 15 of 15 live resource(s) are missing at least one required tag. None currently carries month-to-date cost, so this is the cheapest moment to tag them - before any spend starts and needs attributing.
- Agree tag names and allowed values once (for example a CostCenter list from Finance) so reports group cleanly; this assessment treats "Cost Center", "cost-center" and "CostCenter" as the same tag, but reporting tools may not.
- Re-run this assessment after each tagging wave; the "Not tagged" share and the missing-tags list below should shrink each time.

### Tag quality findings

No naming or value inconsistencies were detected in the tags found on live resources.

### Tagging best-practice standard

| **PracticeWhat it means**                  |                                                                                                                                                                                                                                                          |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Define a small mandatory tag set           | Start with CostCenter, Owner and Environment (add Application or Project if needed). A short standard is followed; a long one is ignored.                                                                                                                |
| Standardize names and allowed values       | One approved spelling per tag and an approved value list (for example environments, cost-center codes). Azure tag names ignore case; values do not.                                                                                                      |
| Enforce with Azure Policy, not reminders   | Use policy to require tags on new resources and to inherit tags from the resource group or subscription. Azure does not copy tags down automatically.                                                                                                    |
| Tag resource groups and subscriptions too  | This gives every resource an owner by default. Microsoft Cost Management also offers a tag inheritance setting on some billing account types, which applies subscription and resource-group tags to cost records; check availability for your agreement. |
| Name a real owner                          | Prefer a team or shared mailbox over one individual, so ownership survives people changing roles.                                                                                                                                                        |
| Keep secrets and personal data out of tags | Tags are visible to anyone who can read the resource and appear in billing data.                                                                                                                                                                         |
| Review on a schedule                       | Re-run this assessment monthly and track the untagged share and quality findings until they reach zero.                                                                                                                                                  |

### Resources missing required tags (start here)

| **ResourceTypeResource GroupStateMissing TagsMTD CostCurrency** |                                                  |                              |             |                                |        |     |
| --------------------------------------------------------------- | ------------------------------------------------ | ---------------------------- | ----------- | ------------------------------ | ------ | --- |
| aa-cloudgenius-cost-control                                     | Microsoft.Automation/automationAccounts          | rg-cloudgenius-cost-control  | **Current** | CostCenter, Owner, Environment | 0.0000 | CAD |
| aa-cloudgenius-cost-control/CloudGenius-Azure-Cost-KillSwitch   | Microsoft.Automation/automationAccounts/runbooks | rg-cloudgenius-cost-control  | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| AD-DC-01                                                        | Microsoft.HybridCompute/machines                 | rg-cloudgenius-arc-servers   | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| AD-DC-01/AzureMonitorWindowsAgent                               | Microsoft.HybridCompute/machines/extensions      | rg-cloudgenius-arc-servers   | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| CG-CA-01                                                        | Microsoft.HybridCompute/machines                 | rg-cloudgenius-sql-witness   | **Current** | CostCenter, Owner, Environment | 0.0000 | CAD |
| CG-CA-01/AzureMonitorWindowsAgent                               | Microsoft.HybridCompute/machines/extensions      | rg-cloudgenius-sql-witness   | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| CG-WSFC-WIT-01                                                  | Microsoft.HybridCompute/machines                 | rg-cloudgenius-sql-witness   | **Current** | CostCenter, Owner, Environment | 0.0000 | CAD |
| cloudgenius-k8s                                                 | Microsoft.Kubernetes/connectedClusters           | rg-cloudgenius-arc-k8s       | **Current** | CostCenter, Owner, Environment | 0.0000 | CAD |
| dcr-cg-ca01-security                                            | Microsoft.Insights/dataCollectionRules           | rg-cloudgenius-sentinel-lab  | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| dcr-cloudgenius-ad-security                                     | Microsoft.Insights/dataCollectionRules           | rg-cloudgenius-sentinel-lab  | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| DefaultQueryPack                                                | microsoft.operationalInsights/querypacks         | LogAnalyticsDefaultResources | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| law-cloudgenius-sentinel                                        | Microsoft.OperationalInsights/workspaces         | rg-cloudgenius-sentinel-lab  | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| NetworkWatcher_canadacentral                                    | Microsoft.Network/networkWatchers                | NetworkWatcherRG             | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| SecurityInsights(law-cloudgenius-sentinel)                      | Microsoft.OperationsManagement/solutions         | rg-cloudgenius-sentinel-lab  | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |
| vnet-cloudgenius-security                                       | Microsoft.Network/virtualNetworks                | rg-cloudgenius-sentinel-lab  | **Current** | CostCenter, Owner, Environment | 0.0000 | —   |

Full list: 15-Untagged-Cost.csv.

## Prioritized executive actions

### Immediate

- **Confirm deleted resources have no residual billable dependencies.**Check for attached or related billable items (for example public IPs, disks, gateways or private endpoints) that may outlive the removed resource. Start with vng-cloudgenius-azure, the largest historical charge.
- **Verify historical charges do not recur in the next billing period.**Re-run this assessment after the next billing cycle and confirm the historical/deleted lines no longer accrue new cost.

### Near-Term

- **Improve CostCenter, Owner, and Environment tagging.**Define the standard, backfill existing resources and enforce it for new deployments (for example with Azure Policy) so spend can be attributed.
- **Establish baseline cost ownership.**Assign an accountable owner to each subscription and resource group so every material cost line has a named owner.
- **Define budgets and alert thresholds where appropriate.**Budget configuration was not assessed here. Set thresholds proportionate to the size and volatility of each subscription.

### Strategic

- **Evaluate commitment discounts only when stable active spend justifies them.**No commitment recommendation is made at this time because the current active-cost baseline is insufficient for a meaningful commitment analysis.
- **Move from showback to chargeback as tagging coverage matures.**Use CostCenter and Owner data to report cost to the teams that drive it, then decide with Finance whether to recharge it.
- **Embed cost governance in platform engineering and landing-zone standards.**Make required tags, budgets and cost-visibility defaults part of subscription and workload provisioning.

## Decisions for leadership

| **DecisionSuggested ownerWhy it matters**                                                           |                             |                                                                                                  |
| --------------------------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------ |
| Confirm the removed resources were intentionally decommissioned and are no longer billing.          | Cloud / infrastructure lead | Charges tied to deleted resources should stop; recurrence would indicate leftover dependencies.  |
| Approve a mandatory tagging standard (CostCenter, Owner, and Environment) with an enforcement date. | CIO / platform owner        | Without ownership tags, cost cannot be attributed, shown back or charged back.                   |
| Nominate a cost owner per subscription and agree budget thresholds.                                 | Finance with IT             | Budgets were not assessed here; thresholds should match each subscription's size and volatility. |
| No commitment purchase (Reservation / Savings Plan) is needed now.                                  | Finance with IT             | The active-cost baseline is not yet large or stable enough to justify one.                       |

## Financial planning notes and scope

Commitment discounts

No commitment recommendation is made at this time because the current active-cost baseline is insufficient for a meaningful commitment analysis.

Capital and operating expenditure

Where Finance distinguishes capital and operating expenditure, use this assessment as an input to Finance review rather than as an accounting classification engine. Final treatment should follow organizational accounting policy and applicable standards.

Currency

All amounts are shown in the billing currency returned by Azure. Different currencies are never added together, and no currency conversion is performed without an approved FX policy.

### Not covered by this assessment

**Azure budgets**Not assessed

**Official Azure cost forecast**Not available from this assessment

**Cost anomaly alerts**Not assessed

**Commitment utilization and savings**Not assessed

## Detailed analysis

### Currency and consolidation

| **CurrencyMTD Actual CostActiveHistorical / DeletedUnmappedHistorical %Indicative Run Rate** |        |        |        |        |      |                |
| -------------------------------------------------------------------------------------------- | ------ | ------ | ------ | ------ | ---- | -------------- |
| CAD                                                                                          | 4.5931 | 0.0000 | 4.5931 | 0.0000 | 100% | Not calculated |

Each currency is a separate total. Nothing is converted or added across currencies.

### Cost by subscription

| **SubscriptionStatusCurrencyMTD CostActiveHistorical / DeletedUnmappedCurrent ResourcesCost Lines** |         |     |        |        |        |        |    |    |
| --------------------------------------------------------------------------------------------------- | ------- | --- | ------ | ------ | ------ | ------ | -- | -- |
| Dev                                                                                                 | Enabled | CAD | 4.5931 | 0.0000 | 4.5931 | 0.0000 | 15 | 23 |
| Prod                                                                                                | Enabled | —   | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0  | 0  |

No cost lines were returned for: Prod. That is expected for an unused subscription; if activity was expected there, confirm the signed-in account has Cost Management Reader on it.

### Historical / deleted resource cost

| **ResourceTypeResource GroupStateLast BilledDeletion CheckMTD CostCurrencyRequired tags** |                                          |                               |                          |            |                   |        |     |                                                                       |
| ----------------------------------------------------------------------------------------- | ---------------------------------------- | ----------------------------- | ------------------------ | ---------- | ----------------- | ------ | --- | --------------------------------------------------------------------- |
| vng-cloudgenius-azure                                                                     | microsoft.network/virtualnetworkgateways | rg-cloudgenius-hybrid-network | **Historical / Deleted** | 2026-09-19 | Confirmed deleted | 4.5326 | CAD | CostCenter: CloudGenius-Lab; Owner: Isaac-Emeteveke; Environment: Dev |
| pip-cloudgenius-azure-vpngw                                                               | microsoft.network/publicipaddresses      | rg-cloudgenius-hybrid-network | **Historical / Deleted** | 2026-09-19 | Confirmed deleted | 0.0605 | CAD | CostCenter: CloudGenius-Lab; Owner: Isaac-Emeteveke; Environment: Dev |

Full list, including 0 historical/deleted resource(s) with zero month-to-date cost: 07-Historical-Deleted-Resource-Cost.csv.

### Top resource costs

| **ResourceTypeResource GroupStateMTD CostCurrencyRequired tags** |                                          |                               |                          |        |     |                                                                       |
| ---------------------------------------------------------------- | ---------------------------------------- | ----------------------------- | ------------------------ | ------ | --- | --------------------------------------------------------------------- |
| vng-cloudgenius-azure                                            | microsoft.network/virtualnetworkgateways | rg-cloudgenius-hybrid-network | **Historical / Deleted** | 4.5326 | CAD | CostCenter: CloudGenius-Lab; Owner: Isaac-Emeteveke; Environment: Dev |
| pip-cloudgenius-azure-vpngw                                      | microsoft.network/publicipaddresses      | rg-cloudgenius-hybrid-network | **Historical / Deleted** | 0.0605 | CAD | CostCenter: CloudGenius-Lab; Owner: Isaac-Emeteveke; Environment: Dev |

Showing up to 25 lines. Complete list: 01-Cost-By-Resource.csv.

### Current Azure resource inventory

| **Resource TypeLive ResourcesWith MTD CostNo MTD CostFully Tagged** |   |   |   |   |
| ------------------------------------------------------------------- | - | - | - | - |
| Microsoft.HybridCompute/machines                                    | 3 | 0 | 3 | 0 |
| Microsoft.HybridCompute/machines/extensions                         | 2 | 0 | 2 | 0 |
| Microsoft.Insights/dataCollectionRules                              | 2 | 0 | 2 | 0 |
| Microsoft.Automation/automationAccounts                             | 1 | 0 | 1 | 0 |
| Microsoft.Automation/automationAccounts/runbooks                    | 1 | 0 | 1 | 0 |
| Microsoft.Kubernetes/connectedClusters                              | 1 | 0 | 1 | 0 |
| Microsoft.Network/networkWatchers                                   | 1 | 0 | 1 | 0 |
| Microsoft.Network/virtualNetworks                                   | 1 | 0 | 1 | 0 |
| microsoft.operationalInsights/querypacks                            | 1 | 0 | 1 | 0 |
| Microsoft.OperationalInsights/workspaces                            | 1 | 0 | 1 | 0 |
| Microsoft.OperationsManagement/solutions                            | 1 | 0 | 1 | 0 |

11 resource type(s), 15 live resource(s) in total. A live resource with zero cost is still Current. Full list: 05-Current-Resources.csv.

### Current resources with no month-to-date cost

| **ResourceTypeResource GroupSubscriptionState**               |                                                  |                              |     |             |
| ------------------------------------------------------------- | ------------------------------------------------ | ---------------------------- | --- | ----------- |
| DefaultQueryPack                                              | microsoft.operationalInsights/querypacks         | LogAnalyticsDefaultResources | Dev | **Current** |
| NetworkWatcher_canadacentral                                  | Microsoft.Network/networkWatchers                | NetworkWatcherRG             | Dev | **Current** |
| cloudgenius-k8s                                               | Microsoft.Kubernetes/connectedClusters           | rg-cloudgenius-arc-k8s       | Dev | **Current** |
| AD-DC-01                                                      | Microsoft.HybridCompute/machines                 | rg-cloudgenius-arc-servers   | Dev | **Current** |
| AD-DC-01/AzureMonitorWindowsAgent                             | Microsoft.HybridCompute/machines/extensions      | rg-cloudgenius-arc-servers   | Dev | **Current** |
| aa-cloudgenius-cost-control                                   | Microsoft.Automation/automationAccounts          | rg-cloudgenius-cost-control  | Dev | **Current** |
| aa-cloudgenius-cost-control/CloudGenius-Azure-Cost-KillSwitch | Microsoft.Automation/automationAccounts/runbooks | rg-cloudgenius-cost-control  | Dev | **Current** |
| dcr-cg-ca01-security                                          | Microsoft.Insights/dataCollectionRules           | rg-cloudgenius-sentinel-lab  | Dev | **Current** |
| dcr-cloudgenius-ad-security                                   | Microsoft.Insights/dataCollectionRules           | rg-cloudgenius-sentinel-lab  | Dev | **Current** |
| vnet-cloudgenius-security                                     | Microsoft.Network/virtualNetworks                | rg-cloudgenius-sentinel-lab  | Dev | **Current** |
| law-cloudgenius-sentinel                                      | Microsoft.OperationalInsights/workspaces         | rg-cloudgenius-sentinel-lab  | Dev | **Current** |
| SecurityInsights(law-cloudgenius-sentinel)                    | Microsoft.OperationsManagement/solutions         | rg-cloudgenius-sentinel-lab  | Dev | **Current** |
| CG-CA-01                                                      | Microsoft.HybridCompute/machines                 | rg-cloudgenius-sql-witness   | Dev | **Current** |
| CG-WSFC-WIT-01                                                | Microsoft.HybridCompute/machines                 | rg-cloudgenius-sql-witness   | Dev | **Current** |
| CG-CA-01/AzureMonitorWindowsAgent                             | Microsoft.HybridCompute/machines/extensions      | rg-cloudgenius-sql-witness   | Dev | **Current** |

15 resource(s) in total (first 25 shown). Full list: 06-Current-Resources-No-MTD-Cost.csv.

### Cost by service

| **ServiceSubscriptionCurrencyMTD CostActiveHistorical / DeletedUnmapped** |     |     |        |        |        |        |
| ------------------------------------------------------------------------- | --- | --- | ------ | ------ | ------ | ------ |
| VPN Gateway                                                               | Dev | CAD | 4.5326 | 0.0000 | 4.5326 | 0.0000 |
| Virtual Network                                                           | Dev | CAD | 0.0605 | 0.0000 | 0.0605 | 0.0000 |
| Automation                                                                | Dev | CAD | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| Azure Arc                                                                 | Dev | CAD | 0.0000 | 0.0000 | 0.0000 | 0.0000 |

### Cost by resource group

| **Resource GroupSubscriptionCurrencyMTD CostActiveHistorical / DeletedUnmapped** |     |     |        |        |        |        |
| -------------------------------------------------------------------------------- | --- | --- | ------ | ------ | ------ | ------ |
| rg-cloudgenius-hybrid-network                                                    | Dev | CAD | 4.5931 | 0.0000 | 4.5931 | 0.0000 |
| rg-cloudgenius-arc-k8s                                                           | Dev | CAD | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| rg-cloudgenius-cost-control                                                      | Dev | CAD | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| rg-cloudgenius-sql-witness                                                       | Dev | CAD | 0.0000 | 0.0000 | 0.0000 | 0.0000 |

### Cost by tag

| **TagTag ValueCurrencyMTD Cost% of TotalActiveHistorical / DeletedUnmappedCost Lines** |                 |     |        |      |        |        |        |   |
| -------------------------------------------------------------------------------------- | --------------- | --- | ------ | ---- | ------ | ------ | ------ | - |
| CostCenter                                                                             | CloudGenius-Lab | CAD | 4.5931 | 100% | 0.0000 | 4.5931 | 0.0000 | 2 |
| CostCenter                                                                             | (Not tagged)    | CAD | 0.0000 | 0%   | 0.0000 | 0.0000 | 0.0000 | 0 |
| Environment                                                                            | Dev             | CAD | 4.5931 | 100% | 0.0000 | 4.5931 | 0.0000 | 2 |
| Environment                                                                            | (Not tagged)    | CAD | 0.0000 | 0%   | 0.0000 | 0.0000 | 0.0000 | 0 |
| Owner                                                                                  | Isaac-Emeteveke | CAD | 4.5931 | 100% | 0.0000 | 4.5931 | 0.0000 | 2 |
| Owner                                                                                  | (Not tagged)    | CAD | 0.0000 | 0%   | 0.0000 | 0.0000 | 0.0000 | 0 |

Required governance tags are shown with an explicit "(Not tagged)" row, so the rows for any one tag add up to the full month-to-date cost. Tags come from live Azure resources; for deleted resources, the tags recorded on the bill are used.

### Cost by other tags found on billed resources

| **TagTag ValueCurrencyMTD Cost% of TotalActiveHistorical / DeletedUnmappedCost Lines** |                                |     |        |      |        |        |        |   |
| -------------------------------------------------------------------------------------- | ------------------------------ | --- | ------ | ---- | ------ | ------ | ------ | - |
| ManagedBy                                                                              | Terraform                      | CAD | 4.5931 | 100% | 0.0000 | 4.5931 | 0.0000 | 2 |
| Project                                                                                | CloudGenius-Azure-PaloAlto-S2S | CAD | 4.5931 | 100% | 0.0000 | 4.5931 | 0.0000 | 2 |

A resource with several tags appears under each of them, so rows for different tags must not be added together. Full list: 13-Cost-By-Tag.csv.

2 further tag value(s) appear only on zero-cost resources and are listed in the CSV.

## Final calculations and reconciliation

| **CurrencyMTD Actual CostActiveHistorical / DeletedUnmappedDays BilledIndicative Run Rate = Active x days in month / days billed + Historical + Unmapped** |        |        |        |        |    |                                    |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------ | ------ | ------ | -- | ---------------------------------- |
| CAD                                                                                                                                                        | 4.5931 | 0.0000 | 4.5931 | 0.0000 | 19 | Not calculated (see run-rate note) |

### Tie-out checks

| **CheckCurrencyCalculatedExpectedDifferenceResult**             |     |        |        |        |      |
| --------------------------------------------------------------- | --- | ------ | ------ | ------ | ---- |
| Active + Historical/Deleted + Unmapped = MTD actual cost        | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Sum of subscriptions = MTD actual cost                          | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Sum of services = MTD actual cost                               | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Sum of resource groups = MTD actual cost                        | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Sum of all resource cost lines = MTD actual cost                | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Tag 'CostCenter': tagged + not tagged = MTD actual cost         | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Tag 'Owner': tagged + not tagged = MTD actual cost              | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Tag 'Environment': tagged + not tagged = MTD actual cost        | CAD | 4.5931 | 4.5931 | 0.0000 | Pass |
| Live resources: with cost + without cost = total live resources | —   | 15     | 15     | 0      | Pass |
| Cost lines aggregated = cost lines read from Azure              | —   | 23     | 23     | 0      | Pass |

10 of 10 checks passed. Every headline figure is recomputed from a different angle; if any check failed, no report would have been produced. Full list: 14-Final-Calculations.csv.

## Appendix - methodology and reconciliation

**How the numbers were produced**

- **Cost source.** Azure Cost Management asynchronous cost-details reports (actual cost, current month) were requested per subscription, polled at the interval Azure specified, downloaded and analyzed locally. The synchronous query interface was not used.
- **Cache.** All cost data was generated fresh by Azure for this run.
- **Coverage.** Every enabled subscription in the tenant was required to complete; if any had failed, no consolidated report would have been produced.
- **Current versus historical.** Billing lines were reconciled to the live Azure Resource Manager inventory by normalized resource ID, then by subscription + resource group + name (resource type must agree). A billed resource is Historical / Deleted only when it has a full resource ID in an assessed subscription that is absent from the live inventory. Zero cost never changes the state. Charges without a resource identity, and non-usage lines such as purchases, refunds and adjustments, are Unmapped.
- **Reconciliation results.** Resource-level matches - by resource ID: 4; by parent resource: 0; by subscription + group + name: 0; not matched: 2.
- **Deletion checks.** Every resource that looked deleted was looked up directly by its exact ID: 2 confirmed deleted, 0 found still existing (treated as Current), 0 could not be verified and stay flagged 'Not verified'.
- **Volume.** 23 cost line(s) processed; 0 dated outside the current month.
- **Run rate.** The Indicative Month-End Run Rate extrapolates ACTIVE spend linearly from the days billed so far and holds historical and unmapped spend flat. It is suppressed when historical/deleted spend distorts the baseline. It is not the Azure Cost Management forecast.
- **Privacy.** Tenant, subscription and billing-account identifiers are intentionally omitted from this report. Supporting CSV files retain subscription and resource identifiers for traceability; handle them accordingly.

**Supporting files**

- 01-Cost-By-Resource.csv
- 02-Cost-By-Subscription.csv
- 03-Cost-By-Service.csv
- 04-Cost-By-Resource-Group.csv
- 05-Current-Resources.csv
- 06-Current-Resources-No-MTD-Cost.csv
- 07-Historical-Deleted-Resource-Cost.csv
- 08-Cost-By-Currency.csv
- 09-Raw-Cost-Details-Normalized.csv
- 10-Executive-Summary.csv
- 11-Executive-Actions.csv
- 12-Governance-Readiness.csv
- 13-Cost-By-Tag.csv
- 14-Final-Calculations.csv
- 15-Untagged-Cost.csv
- 16-Tag-Quality-Findings.csv
- Executive-Summary.json

Azure FinOps Executive Assessment v7.0.0. Figures are Azure-reported month-to-date actual cost; nothing in this report was estimated other than the clearly labelled indicative run rate.