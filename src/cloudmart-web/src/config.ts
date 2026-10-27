// Runtime configuration, fetched from /config.json at startup rather than baked in at build time.
// The pipeline overwrites config.json per environment, so one build artifact is promoted dev -> test -> prod.

export interface RuntimeConfig {
  /** Empty = same origin (Vite dev proxy, or Front Door routing /api/* to the API). */
  apiBaseUrl: string;
  entra: {
    clientId: string;
    tenantId: string;
    /** e.g. api://<api-client-id>/access_as_user */
    apiScope: string;
  };
  appInsightsConnectionString: string;
}

const defaults: RuntimeConfig = {
  apiBaseUrl: '',
  entra: { clientId: '', tenantId: '', apiScope: '' },
  appInsightsConnectionString: '',
};

let current: RuntimeConfig = defaults;

export async function loadConfig(): Promise<RuntimeConfig> {
  try {
    const response = await fetch('/config.json', { cache: 'no-store' });
    if (response.ok) {
      const loaded = (await response.json()) as Partial<RuntimeConfig>;
      current = { ...defaults, ...loaded, entra: { ...defaults.entra, ...loaded.entra } };
    }
  } catch {
    // Fall back to defaults: local, anonymous, same-origin.
  }
  return current;
}

export const config = (): RuntimeConfig => current;
