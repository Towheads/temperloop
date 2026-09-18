- **`/assess` now documents the plan-schema `activation:` block and validates the
  plan note it just wrote** (#1951). Step 2's `activation` optional field spells out
  the product-source predicate, the three rule-14 exemptions (`kind: spike`,
  docs-only, no product-source `files:`) and the wrap-immune absence-proof idiom
  (temperloop#944); a new Step 4 sub-step runs `plan.sh validate` on the fresh note
  and Step 5 carries its outcome on an always-present `validated:` notice line.
  Previously the spec never mentioned the block and never invoked the validator, so
  a first-write plan reached `/build` Step 1 to fail rule 14 there.
