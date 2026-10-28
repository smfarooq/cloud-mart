import { useCallback, useEffect, useMemo, useState } from 'react';
import { api, imageUrl } from '../api';
import { errorMessage, money } from '../format';
import { trackProductView } from '../telemetry';
import type { Order, Product, TrendingProduct } from '../types';

interface ShopProps {
  canOrder: boolean;
  showTrending: boolean;
  onOrdered: (order: Order) => void;
}

export function Shop({ canOrder, showTrending, onOrdered }: ShopProps) {
  const [products, setProducts] = useState<Product[]>([]);
  const [trending, setTrending] = useState<TrendingProduct[]>([]);
  const [category, setCategory] = useState('all');
  const [selected, setSelected] = useState<string | null>(null);
  const [cart, setCart] = useState<Record<string, number>>({});
  const [simulateFailure, setSimulateFailure] = useState(false);
  // One key per checkout attempt. Retrying after an error reuses it, so a request that reached the API but lost its
  // response can't create a second order. A changed cart or a successful order starts a new one.
  const [checkoutKey, setCheckoutKey] = useState(() => crypto.randomUUID());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadProducts = useCallback(async () => {
    try {
      setProducts(await api.products());
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);

  useEffect(() => {
    void loadProducts();
  }, [loadProducts]);

  // View counts arrive asynchronously (Event Hubs -> Function), so poll the leaderboard.
  useEffect(() => {
    if (!showTrending) return;
    const refresh = () => api.trending().then(setTrending).catch(() => {});
    void refresh();
    const timer = window.setInterval(refresh, 8000);
    return () => window.clearInterval(timer);
  }, [showTrending]);

  const categories = useMemo(() => ['all', ...new Set(products.map((p) => p.category))], [products]);
  const visible = category === 'all' ? products : products.filter((p) => p.category === category);
  const lines = Object.entries(cart)
    .map(([id, quantity]) => ({ product: products.find((p) => p.id === id), quantity }))
    .filter((l): l is { product: Product; quantity: number } => l.product !== undefined && l.quantity > 0);
  const total = lines.reduce((sum, l) => sum + l.product.price * l.quantity, 0);

  const toggleDetails = (product: Product) => {
    if (selected !== product.id) trackProductView(product.id);
    setSelected(selected === product.id ? null : product.id);
  };

  const changeQuantity = (id: string, delta: number) => {
    setCart((current) => ({ ...current, [id]: Math.max(0, (current[id] ?? 0) + delta) }));
    setCheckoutKey(crypto.randomUUID());
  };

  const checkout = async () => {
    setBusy(true);
    try {
      const order = await api.placeOrder(
        lines.map((l) => ({ productId: l.product.id, quantity: l.quantity })),
        simulateFailure,
        checkoutKey,
      );
      setCart({});
      setSimulateFailure(false);
      setCheckoutKey(crypto.randomUUID());
      onOrdered(order);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="shop">
      <section>
        {showTrending && trending.length > 0 && (
          <div className="trending">
            <span className="label">Trending</span>
            {trending.map((t) => (
              <span key={t.product.id} className="chip">
                {t.product.name} <strong>{t.views}</strong>
              </span>
            ))}
          </div>
        )}

        <div className="filters" role="group" aria-label="Category">
          {categories.map((c) => (
            <button key={c} className={c === category ? 'chip active' : 'chip'} onClick={() => setCategory(c)}>
              {c}
            </button>
          ))}
          <button className="ghost small" onClick={() => void loadProducts()}>
            Refresh
          </button>
        </div>

        {error && <p className="error">{error}</p>}

        <div className="grid">
          {visible.map((product) => {
            const src = imageUrl(product);
            return (
              <article key={product.id} className={selected === product.id ? 'card selected' : 'card'}>
                <button className="thumb" onClick={() => toggleDetails(product)} aria-label={`Details for ${product.name}`}>
                  {src ? <img src={src} alt="" loading="lazy" /> : <span className="placeholder">{initials(product.name)}</span>}
                </button>
                <div className="card-body">
                  <div className="card-title">
                    <h3>{product.name}</h3>
                    <span className="price">{money(product.price)}</span>
                  </div>
                  <div className="muted small">
                    {product.category} · {product.stock} in stock
                  </div>
                  {selected === product.id && <p className="description">{product.description}</p>}
                  <div className="card-actions">
                    <button className="ghost small" onClick={() => toggleDetails(product)}>
                      {selected === product.id ? 'Hide' : 'Details'}
                    </button>
                    <button className="primary small" onClick={() => changeQuantity(product.id, 1)}>
                      Add to cart
                    </button>
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      </section>

      <aside className="cart">
        <h2>Cart</h2>
        {lines.length === 0 && <p className="muted">Empty. "Details" sends a product_view event through the telemetry pipeline.</p>}
        {lines.map(({ product, quantity }) => (
          <div key={product.id} className="cart-line">
            <span>{product.name}</span>
            <span className="qty">
              <button className="ghost small" onClick={() => changeQuantity(product.id, -1)} aria-label="Remove one">
                −
              </button>
              {quantity}
              <button className="ghost small" onClick={() => changeQuantity(product.id, 1)} aria-label="Add one">
                +
              </button>
            </span>
            <span>{money(product.price * quantity)}</span>
          </div>
        ))}
        {lines.length > 0 && (
          <>
            <div className="cart-total">
              <span>Total</span>
              <strong>{money(total)}</strong>
            </div>
            <label className="check">
              <input type="checkbox" checked={simulateFailure} onChange={(e) => setSimulateFailure(e.target.checked)} />
              Simulate a processing failure (poison message → dead-letter queue)
            </label>
            <button className="primary block" disabled={!canOrder || busy} onClick={() => void checkout()}>
              {busy ? 'Placing order…' : canOrder ? 'Place order' : 'Sign in to order'}
            </button>
          </>
        )}
      </aside>
    </div>
  );
}

const initials = (name: string) =>
  name
    .split(' ')
    .slice(0, 2)
    .map((w) => w[0])
    .join('')
    .toUpperCase();
