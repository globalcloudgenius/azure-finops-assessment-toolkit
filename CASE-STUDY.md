# Case Study — Azure FinOps Assessment Toolkit

## Executive summary

This project demonstrates a repeatable Azure FinOps assessment approach that combines live Azure Resource Manager inventory with Azure Cost Management billing data.

The objective is to answer four practical questions:

1. What is the organization paying for?
2. Which billed resources still exist?
3. Which charges relate to resources that have been deleted?
4. Is the environment ready for accountable cost governance?

## Business problem

Azure billing and live-resource state are often reviewed separately. That can make it difficult to determine whether current charges correspond to active workloads, historical resources, shared services, or governance gaps.

A useful assessment needs to reconcile cost and technical state rather than simply export billing data.

## Approach

The toolkit:

- discovers enabled subscriptions;
- inventories live Azure resources;
- retrieves actual month-to-date Cost Management data;
- normalizes resource identities;
- reconciles billing records against the live ARM estate;
- independently checks resources that appear deleted;
- assesses governance tags;
- performs financial tie-out checks;
- generates an executive-ready assessment.

## Validated result

A real CloudGenius assessment run identified:

- 2 enabled subscriptions;
- 15 current ARM resources across 11 resource types;
- 4.5931 CAD month-to-date actual cost;
- 0.0000 CAD active spend;
- 4.5931 CAD historical/deleted spend;
- 0.0000 CAD unmapped spend;
- 10 of 10 reconciliation checks passed.

The largest charge was tied to a deleted Azure VPN Gateway and represented 98.7% of month-to-date spend. A direct resource-ID lookup confirmed that the resource no longer existed.

The same assessment also found that none of the 15 live resources carried the required CostCenter, Owner, and Environment tags.

## Why this matters

The result demonstrates the difference between simply seeing a bill and understanding the state behind the bill.

For an organization, this type of assessment can support:

- cloud-cost reviews;
- post-decommission validation;
- cost-ownership improvement;
- showback/chargeback readiness;
- Azure Policy remediation;
- governance baselining;
- executive reporting.

## Consulting outcome

A client engagement based on this pattern would normally finish with:

- current-state findings;
- validated cost drivers;
- identified residual/historical charges;
- tagging and governance gaps;
- prioritized actions;
- executive report;
- implementation roadmap where required.

## Evidence

- Working PowerShell implementation: [src/Azure-FinOps-Assessment.ps1](./src/Azure-FinOps-Assessment.ps1)
- Executive sample report: [sample-output/Azure-FinOps-Executive-Assessment-Sample.pdf](./sample-output/Azure-FinOps-Executive-Assessment-Sample.pdf)
- Searchable sample output: [sample-output/Azure-FinOps-Executive-Assessment-Sample.md](./sample-output/Azure-FinOps-Executive-Assessment-Sample.md)

## Engagement fit

Relevant for organizations looking for:

- Azure FinOps assessment;
- cost-governance review;
- cloud architecture assessment;
- subscription/resource accountability;
- Azure governance implementation;
- technical remediation following assessment.

**Consulting inquiries:** advisory@cloudgenius.ca
