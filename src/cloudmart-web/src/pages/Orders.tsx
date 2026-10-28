import { useCallback, useEffect, useState } from 'react';
import { api } from '../api';
import { errorMessage, money, timeAgo } from '../format';
import type { Order } from '../types';

export function Orders({ isAdmin }: { isAdmin: boolean }) {
  const [orders, setOrders] = useState<Order[]>([]);
  const [all, setAll] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setOrders(await api.orders(all));
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [all]);

  useEffect(() => {
    void load();
  }, [load]);

  // Poll while anything is Pending: the status flips when the Service Bus consumer finishes.
  const hasPending = orders.some((o) => o.status === 'Pending');
  useEffect(() => {
    if (!hasPending) return;
    const timer = window.setInterval(() => void load(), 2500);
    return () => window.clearInterval(timer);
  }, [hasPending, load]);

  return (
    <section className="orders">
      <div className="section-head">
        <h2>{all ? 'All orders' : 'My orders'}</h2>
        <div className="row">
          {hasPending && <span className="muted small">Polling for status changes…</span>}
          {isAdmin && (
            <label className="check">
              <input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} />
              All customers
            </label>
          )}
          <button className="ghost small" onClick={() => void load()}>
            Refresh
          </button>
        </div>
      </div>

      {error && <p className="error">{error}</p>}
      {orders.length === 0 && !error && <p className="muted">No orders yet.</p>}

      <div className="order-list">
        {orders.map((order) => (
          <article key={order.id} className="order">
            <div className="order-head">
              <span className={`status ${order.status.toLowerCase()}`}>{order.status}</span>
              {order.reviewRequired && <span className="pill warn">High value · review</span>}
              <code className="muted small">{order.id}</code>
              <span className="muted small">{timeAgo(order.createdUtc)}</span>
              <strong className="order-total">{money(order.total)}</strong>
            </div>
            <ul className="order-lines">
              {order.lines.map((line) => (
                <li key={line.productId}>
                  {line.quantity} × {line.productName} <span className="muted">@ {money(line.unitPrice)}</span>
                </li>
              ))}
            </ul>
            {order.statusReason && <p className="muted small">{order.statusReason}</p>}
            {(order.paymentId || order.trackingNumber) && (
              <p className="muted small">
                {order.paymentId && (
                  <>
                    Payment <code>{order.paymentId}</code>
                  </>
                )}
                {order.paymentId && order.trackingNumber && ' · '}
                {order.trackingNumber && (
                  <>
                    Tracking <code>{order.trackingNumber}</code>
                  </>
                )}
              </p>
            )}
            {all && <p className="muted small">Customer: {order.customerName}</p>}
          </article>
        ))}
      </div>
    </section>
  );
}
