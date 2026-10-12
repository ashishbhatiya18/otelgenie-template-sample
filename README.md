# otelgenie template (sample)

A sample template for otelgenie. It says what can be collected and how: collector
configuration per component in `catalog/`, the scripts that check and install in
`scripts/`, and versions, images and limits in `otelgenie.json`.

To try it:

```
otelgenie config template-url git@github.com:ashishbhatiya18/otelgenie-template-sample.git
otelgenie update
otelgenie serve --open
```

`otelgenie update` checks the template before using it. One with problems is reported and
the template already in use is kept.

Nothing here is a secret. Access tokens are typed where the installers run and are never
part of a template.
