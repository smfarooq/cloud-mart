import { getAccessToken } from './auth';
import { config } from './config';
import type { HealthReport, Me, Order, PlatformInfo, Product, TelemetryEvent, TrendingProduct, UploadTarget } from './types';

export class ApiError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export const apiUrl = (path: string) => `${config().apiBaseUrl.replace(/\/$/, '')}${path}`;

export const imageUrl = (product: Product) => (product.imageUrl ? apiUrl(product.imageUrl) : null);

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  const token = await getAccessToken();
  if (token) headers.set('Authorization', `Bearer ${token}`);
  if (init.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');

  const response = await fetch(apiUrl(path), { ...init, headers });
  if (!response.ok) throw new ApiError(response.status, await describeError(response));

  const text = await response.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

async function describeError(response: Response): Promise<string> {
  try {
    const problem = await response.json();
    return problem.detail ?? problem.title ?? `${response.status} ${response.statusText}`;
  } catch {
    return `${response.status} ${response.statusText}`;
  }
}

const json = (body: unknown): RequestInit => ({ method: 'POST', body: JSON.stringify(body) });

export const api = {
  me: () => request<Me>('/api/me'),
  platform: () => request<PlatformInfo>('/api/platform/info'),
  health: async (): Promise<HealthReport> => (await fetch(apiUrl('/health/ready'))).json(),

  products: () => request<Product[]>('/api/products'),
  trending: () => request<TrendingProduct[]>('/api/products/trending'),
  saveProduct: (product: Partial<Product>) => request<Product>('/api/products', json(product)),

  orders: (all = false) => request<Order[]>(`/api/orders${all ? '?all=true' : ''}`),
  placeOrder: (lines: { productId: string; quantity: number }[], simulateFailure: boolean) =>
    request<Order>('/api/orders', json({ lines, simulateFailure })),

  chaos: (kind: 'exception' | 'latency' | 'dependency') => request<unknown>(`/api/platform/chaos/${kind}`, { method: 'POST' }),

  /** Fire-and-forget; keepalive lets it finish while the page unloads. */
  telemetry: (events: TelemetryEvent[]) =>
    fetch(apiUrl('/api/telemetry'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(events),
      keepalive: true,
    }),

  /**
   * Valet-key upload: the API returns where to PUT the file. In Azure that is Blob Storage with a short-lived SAS
   * (so the bearer token must NOT be sent there); locally it is the API itself.
   */
  uploadImage: async (productId: string, file: File): Promise<UploadTarget> => {
    const target = await request<UploadTarget>(
      `/api/products/${encodeURIComponent(productId)}/image-upload`,
      json({ fileName: file.name, contentType: file.type }),
    );

    const toApi = target.uploadUrl.startsWith('/');
    const headers = new Headers(target.headers);
    if (toApi) {
      const token = await getAccessToken();
      if (token) headers.set('Authorization', `Bearer ${token}`);
    }

    const response = await fetch(toApi ? apiUrl(target.uploadUrl) : target.uploadUrl, { method: target.method, headers, body: file });
    if (!response.ok) throw new ApiError(response.status, `Upload failed: ${response.status} ${response.statusText}`);
    return target;
  },
};
