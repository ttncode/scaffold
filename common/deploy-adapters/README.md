# Deploy adapters

Empty on purpose. Deployment is deferred — see the scaffold toolbox's
ADR-0014 (not shipped here) for the seven seams that make adding a target
roughly one session of work.

An adapter here will hold a `deploy.env` describing the target and a workflow
fragment that fills in the `deploy` job a later task adds, gated off, to the
release workflow.
