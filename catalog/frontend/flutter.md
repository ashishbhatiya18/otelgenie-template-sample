#! otelgenie component=flutter signal=any role=guide category=Frontend title="Flutter application: screens and calls to your APIs, sent from the device"
#! discover input=endpoint -> OTEL_GATEWAY_ENDPOINT
#! discover input=project -> OTELGENIE_PROJECT
#! discover input=env -> OTELGENIE_ENV

# Flutter application

## Before you start

A frontend runs on the user's device, not next to a collector, so it sends
straight to an address the device can reach.

- Ask whoever runs `${env:OTEL_GATEWAY_ENDPOINT}` for the address frontends
  should use. It is often a separate, public one.
- Never put the collector access token in a frontend build: anyone can read
  it there. The public address has to accept data without it, or with a key
  meant to be public.

## What exists for Flutter

There is no OpenTelemetry SDK for Dart from the OpenTelemetry project itself.
The community package `opentelemetry` on pub.dev implements tracing and an
OTLP exporter and is what this guide uses. Check its current version and
status before depending on it.

## Install

```sh
flutter pub add opentelemetry
```

## Start it in main()

```dart
import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';

void main() {
  final provider = TracerProviderBase(
    resource: Resource([
      Attribute.fromString('service.name', 'YOUR-APP-NAME'),
      Attribute.fromString('service.namespace', '${env:OTELGENIE_PROJECT}'),
      Attribute.fromString('deployment.environment.name', '${env:OTELGENIE_ENV}'),
    ]),
    processors: [
      BatchSpanProcessor(CollectorExporter(Uri.parse('PUBLIC-ADDRESS/v1/traces'))),
    ],
  );
  registerGlobalTracerProvider(provider);
  runApp(const MyApp());
}
```

Calls to your APIs are not traced automatically. Wrap them, and pass the
trace on so it continues into the microservices:

```dart
final tracer = globalTracerProvider.getTracer('app');
final span = tracer.startSpan('GET /orders');
// add the W3C traceparent header to the request from span.spanContext
span.end();
```

## Check

Run a debug build and look for requests to `/v1/traces` in the network
profiler of Flutter DevTools.
