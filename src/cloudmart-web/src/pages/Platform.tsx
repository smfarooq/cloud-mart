import { useCallback, useEffect, useState } from 'react';
import { api } from '../api';
import { errorMessage } from '../format';
import type { HealthReport, PlatformInfo } from '../types';

// Which learning phase lights each provider up, and what "local" means for it.
const providerRows: { key: keyof PlatformInfo['providers']; label: string; phase: string; local: string }[] = [
  { key: 'catalog', label: 'Catalog', phase: '4 · Data', local: 'In-memory' },
  { key: 'orders', label: 'Orders', phase: '4 · Data', local: 'In-memory' },
  { key: 'images', label: 'Images', phase: '4 · Data', local: 'In-memory' },
  { key: 'messaging', label: 'Order events', phase: '5 · Messaging', local: 'In-process' },
  { key: 'telemetry', label: 'Click stream', phase: '5 · Messaging', local: 'In-process' },
];

const integrationLabels: Record<string, string> = {
  keyVault: 'Key Vault configuration provider',
  paymentKeyLoaded: 'Secret PaymentGateway--ApiKey loaded',
  appConfiguration: 'App Configuration + feature flags',
  redisCache: 'Azure Managed Redis (L2 cache)',
  applicationInsights: 'Application Insights (OpenTelemetry)',
  frontDoorLock: 'Front Door header lock (X-Azure-FDID)',
};

export function Platform() {
  const [info, setInfo] = useState<PlatformInfo | null>(null);
  const [health, setHealth] = useState<HealthReport | null>(null);
  const [spread, setSpread] = useState<Record<string, number> | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [platform, ready] = await Promise.all([api.platform(), api.health()]);
      setInfo(platform);
      setHealth(ready);
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // Scale out (phase 3) or put Front Door in front of two regions (phase 10), then watch the spread change.
  const sample = async () => {
    const counts: Record<string, number> = {};
    const results = await Promise.allSettled(Array.from({ length: 20 }, () => api.platform()));
    for (const result of results) {
      const key = result.status === 'fulfilled' ? `${result.value.hosting.region ?? '?'} / ${result.value.hosting.instance}` : 'failed';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    setSpread(counts);
  };

  if (error) return <p className="error">Platform info unavailable: {error}</p>;
  if (!info) return <p className="muted">Loading…</p>;

  return (
    <div className="platform">
      <section className="panel">
        <h2>Hosting</h2>
        <dl className="facts">
          <dt>Model</dt>
          <dd>{info.hosting.model}</dd>
          <dt>Region</dt>
          <dd>{info.hosting.region ?? '—'}</dd>
          <dt>Instance</dt>
          <dd>
            <code>{info.hosting.instance}</code>
          </dd>
          <dt>Detail</dt>
          <dd>{info.hosting.detail ?? '—'}</dd>
          <dt>Runtime</dt>
          <dd>
            {info.framework} · {info.environment} · v{info.version.split('+')[0]}
          </dd>
          <dt>Auth</dt>
          <dd>{info.authMode}</dd>
        </dl>
        <button className="ghost small" onClick={() => void sample()}>
          Call the API 20 times
        </button>
        {spread && (
          <ul className="spread">
            {Object.entries(spread).map(([key, count]) => (
              <li key={key}>
                <code>{key}</code> × {count}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="panel">
        <h2>Providers</h2>
        <table>
          <thead>
            <tr>
              <th>Boundary</th>
              <th>Active</th>
              <th>Phase</th>
            </tr>
          </thead>
          <tbody>
            {providerRows.map((row) => {
              const value = info.providers[row.key];
              return (
                <tr key={row.key}>
                  <td>{row.label}</td>
                  <td>
                    <span className={value === row.local ? 'pill' : 'pill ok'}>{value}</span>
                  </td>
                  <td className="muted small">{row.phase}</td>
                </tr>
              );
            })}
          </tbody>
        </table>

        <h3>Integrations</h3>
        <ul className="checklist">
          {Object.entries(info.integrations).map(([key, on]) => (
            <li key={key} className={on ? 'on' : 'off'}>
              {integrationLabels[key] ?? key}
            </li>
          ))}
          {Object.entries(info.features).map(([key, on]) => (
            <li key={key} className={on ? 'on' : 'off'}>
              Feature flag: {key}
            </li>
          ))}
        </ul>
      </section>

      <section className="panel">
        <div className="section-head">
          <h2>Readiness</h2>
          <button className="ghost small" onClick={() => void load()}>
            Re-check
          </button>
        </div>
        <p>
          <span className={health?.status === 'Healthy' ? 'pill ok' : 'pill bad'}>{health?.status ?? 'unknown'}</span>{' '}
          <code className="muted small">GET /health/ready</code>
        </p>
        {health && Object.keys(health.dependencies).length === 0 && <p className="muted small">No Azure dependencies configured yet.</p>}
        <ul className="checklist">
          {health &&
            Object.entries(health.dependencies).map(([name, result]) => (
              <li key={name} className={result === 'ok' ? 'on' : 'off'}>
                <strong>{name}</strong> {result !== 'ok' && <span className="error small">{result}</span>}
              </li>
            ))}
        </ul>
      </section>
    </div>
  );
}
