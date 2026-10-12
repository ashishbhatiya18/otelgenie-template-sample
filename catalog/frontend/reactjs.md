#! otelgenie component=reactjs signal=any role=guide category=Frontend title="React web application: page loads, route changes and calls to your APIs, sent from the browser"
#! discover input=endpoint -> OTEL_GATEWAY_ENDPOINT
#! discover input=project -> OTELGENIE_PROJECT
#! discover input=env -> OTELGENIE_ENV

# React web application

## Before you start

A frontend runs on the user's device, not next to a collector, so it sends
straight to an address the device can reach.

- Ask whoever runs `${env:OTEL_GATEWAY_ENDPOINT}` for the address frontends
  should use. It is often a separate, public one.
- Never put the collector access token in a frontend build: anyone can read
  it there. The public address has to accept data without it, or with a key
  meant to be public.
- The address must allow your site's origin (CORS), including the
  `traceparent` header on your own API calls so browser and backend traces join up.

## Install

```sh
npm install @opentelemetry/api @opentelemetry/sdk-trace-web @opentelemetry/resources \
  @opentelemetry/exporter-trace-otlp-http @opentelemetry/context-zone \
  @opentelemetry/instrumentation @opentelemetry/instrumentation-document-load \
  @opentelemetry/instrumentation-fetch @opentelemetry/instrumentation-xml-http-request
```

## Start it before React renders

```js
// src/telemetry.js, imported first in src/index.js
import { WebTracerProvider, BatchSpanProcessor } from '@opentelemetry/sdk-trace-web';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { ZoneContextManager } from '@opentelemetry/context-zone';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { DocumentLoadInstrumentation } from '@opentelemetry/instrumentation-document-load';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { XMLHttpRequestInstrumentation } from '@opentelemetry/instrumentation-xml-http-request';

const provider = new WebTracerProvider({
  resource: resourceFromAttributes({
    'service.name': 'YOUR-FRONTEND-NAME',
    'service.namespace': '${env:OTELGENIE_PROJECT}',
    'deployment.environment.name': '${env:OTELGENIE_ENV}',
  }),
  spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({ url: 'PUBLIC-ADDRESS/v1/traces' }))],
});
provider.register({ contextManager: new ZoneContextManager() });

// List your API origins so the trace continues into the microservices.
const apis = [/https:\/\/api\.example\.com/];
registerInstrumentations({
  instrumentations: [
    new DocumentLoadInstrumentation(),
    new FetchInstrumentation({ propagateTraceHeaderCorsUrls: apis }),
    new XMLHttpRequestInstrumentation({ propagateTraceHeaderCorsUrls: apis }),
  ],
});
```

## Check

Open the site with the browser's network panel showing. Requests to
`/v1/traces` should return 200 a few seconds after the page loads.
