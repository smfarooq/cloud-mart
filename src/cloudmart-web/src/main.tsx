import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { AuthProvider, createMsal } from './auth';
import { loadConfig } from './config';
import { initTelemetry } from './telemetry';
import './styles.css';

async function bootstrap() {
  const cfg = await loadConfig();
  initTelemetry(cfg.appInsightsConnectionString);
  const msal = await createMsal(cfg);

  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <AuthProvider msal={msal}>
        <App />
      </AuthProvider>
    </StrictMode>,
  );
}

bootstrap().catch((error: unknown) => {
  document.getElementById('root')!.textContent = `CloudMart failed to start: ${String(error)}`;
});
