import { useEffect, useState } from 'react';
import { api } from './api';
import { useAuth } from './auth';
import { Admin } from './pages/Admin';
import { Orders } from './pages/Orders';
import { Platform } from './pages/Platform';
import { Shop } from './pages/Shop';
import type { Me, PlatformInfo } from './types';

type Tab = 'shop' | 'orders' | 'admin' | 'platform';

export function App() {
  const auth = useAuth();
  const [tab, setTab] = useState<Tab>('shop');
  const [me, setMe] = useState<Me | null>(null);
  const [platform, setPlatform] = useState<PlatformInfo | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  useEffect(() => {
    api.platform().then(setPlatform).catch(() => setPlatform(null));
  }, []);

  useEffect(() => {
    if (!auth.signedIn) {
      setMe(null);
      return;
    }
    api.me().then(setMe).catch(() => setMe(null));
  }, [auth.signedIn]);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(null), 6000);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const tabs: { id: Tab; label: string; visible: boolean }[] = [
    { id: 'shop', label: 'Shop', visible: true },
    { id: 'orders', label: 'My orders', visible: auth.signedIn },
    { id: 'admin', label: 'Admin', visible: me?.isAdmin ?? false },
    { id: 'platform', label: 'Platform', visible: true },
  ];

  const onOrdered = () => {
    setToast(`Order accepted (HTTP 202) and is Pending. Fulfillment runs asynchronously; watch the status change here.`);
    setTab('orders');
  };

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <svg viewBox="0 0 32 32" aria-hidden="true">
            <path d="M8 24h17a6 6 0 0 0 0-12 8 8 0 0 0-15-2A7 7 0 0 0 8 24z" />
          </svg>
          CloudMart
        </div>
        <nav className="tabs" aria-label="Sections">
          {tabs
            .filter((t) => t.visible)
            .map((t) => (
              <button key={t.id} className={t.id === tab ? 'tab active' : 'tab'} onClick={() => setTab(t.id)}>
                {t.label}
              </button>
            ))}
        </nav>
        <div className="user">
          {!auth.enabled && <span className="pill warn" title="Entra ID is not configured (phase 6)">Auth off · local admin</span>}
          {auth.enabled && auth.signedIn && (
            <>
              <span className="muted">{auth.userName}</span>
              <button className="ghost" onClick={() => void auth.signOut()}>
                Sign out
              </button>
            </>
          )}
          {auth.enabled && !auth.signedIn && (
            <button className="primary" onClick={() => void auth.signIn()}>
              Sign in
            </button>
          )}
        </div>
      </header>

      {platform?.bannerMessage && <div className="banner">{platform.bannerMessage}</div>}

      <main>
        {tab === 'shop' && <Shop canOrder={auth.signedIn} showTrending={platform?.features.Trending ?? false} onOrdered={onOrdered} />}
        {tab === 'orders' && <Orders isAdmin={me?.isAdmin ?? false} />}
        {tab === 'admin' && <Admin onMessage={setToast} />}
        {tab === 'platform' && <Platform />}
      </main>

      {toast && (
        <div className="toast" role="status">
          {toast}
        </div>
      )}

      <footer className="footer muted">
        {platform
          ? `${platform.hosting.model}${platform.hosting.region ? ` · ${platform.hosting.region}` : ''} · instance ${platform.hosting.instance} · ${platform.framework}`
          : 'API unreachable'}
      </footer>
    </div>
  );
}
