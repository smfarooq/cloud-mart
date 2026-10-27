import { ApplicationInsights } from '@microsoft/applicationinsights-web';
import { api } from './api';
import type { TelemetryEvent } from './types';

// Two telemetry paths, on purpose:
//  1. Application Insights JS SDK: page views, browser timings, and correlation headers on API calls, so one trace
//     spans browser -> API -> Service Bus -> Function in the Application Map (phase 7).
//  2. Business click-stream: product views batched to POST /api/telemetry -> Event Hubs -> Function (phase 5).

let appInsights: ApplicationInsights | null = null;
const sessionId = crypto.randomUUID();
let buffer: TelemetryEvent[] = [];
let flushTimer: number | undefined;

export function initTelemetry(connectionString: string) {
  if (connectionString) {
    appInsights = new ApplicationInsights({
      config: {
        connectionString,
        enableAutoRouteTracking: true,
        enableCorsCorrelation: true,
        // Don't add trace headers to SAS uploads or sign-in calls.
        correlationHeaderExcludedDomains: ['*.blob.core.windows.net', 'login.microsoftonline.com'],
      },
    });
    appInsights.loadAppInsights();
    appInsights.trackPageView();
  }
  window.addEventListener('pagehide', flush);
}

export function trackProductView(productId: string) {
  appInsights?.trackEvent({ name: 'product_view' }, { productId });
  buffer.push({ type: 'product_view', productId, sessionId, timestamp: new Date().toISOString() });
  window.clearTimeout(flushTimer);
  flushTimer = window.setTimeout(flush, 2000);
}

function flush() {
  const events = buffer.splice(0, 100);
  if (events.length > 0) void api.telemetry(events).catch(() => {});
}
