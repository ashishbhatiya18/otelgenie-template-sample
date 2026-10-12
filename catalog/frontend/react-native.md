#! otelgenie component=react-native signal=any role=guide category=Frontend title="React Native application: screens and calls to your APIs, sent from the device"
#! discover input=endpoint -> OTEL_GATEWAY_ENDPOINT
#! discover input=project -> OTELGENIE_PROJECT
#! discover input=env -> OTELGENIE_ENV

# React Native application

## Before you start

A frontend runs on the user's device, not next to a collector, so it sends
straight to an address the device can reach.

- Ask whoever runs `${env:OTEL_GATEWAY_ENDPOINT}` for the address frontends
  should use. It is often a separate, public one.
- Never put the collector access token in a frontend build: anyone can read
  it there. The public address has to accept data without it, or with a key
  meant to be public.

## Install

```sh
npm install @opentelemetry/api @opentelemetry/sdk-trace-base @opentelemetry/resources \
  @opentelemetry/exporter-trace-otlp-http @opentelemetry/instrumentation \
  @opentelemetry/instrumentation-fetch
```

## Start it before the app registers

```js
// telemetry.js, imported first in index.js
import { BasicTracerProvider, BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { trace } from '@opentelemetry/api';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';

const provider = new BasicTracerProvider({
  resource: resourceFromAttributes({
    'service.name': 'YOUR-APP-NAME',
    'service.namespace': '${env:OTELGENIE_PROJECT}',
    'deployment.environment.name': '${env:OTELGENIE_ENV}',
  }),
  spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({ url: 'PUBLIC-ADDRESS/v1/traces' }))],
});
trace.setGlobalTracerProvider(provider);

registerInstrumentations({
  instrumentations: [new FetchInstrumentation({ propagateTraceHeaderCorsUrls: [/.*/] })],
});
```

React Native has no page-load event. Wrap a screen or an action yourself where
you want its timing:

```js
const tracer = trace.getTracer('app');
tracer.startActiveSpan('Checkout screen', (span) => { /* ... */ span.end(); });
```

## Check

Run the app against a debug build and watch the network inspector for
requests to `/v1/traces`. Spans are sent in batches, so allow a few seconds,
and flush when the app goes to the background if short sessions matter.
