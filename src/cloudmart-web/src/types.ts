export interface Product {
  id: string;
  category: string;
  name: string;
  description: string;
  price: number;
  stock: number;
  imageUrl?: string | null;
  updatedUtc: string;
}

export interface TrendingProduct {
  product: Product;
  views: number;
}

export type OrderStatus = 'Pending' | 'Confirmed' | 'Rejected';

export interface OrderLine {
  productId: string;
  productName: string;
  unitPrice: number;
  quantity: number;
}

export interface Order {
  id: string;
  customerId: string;
  customerName: string;
  status: OrderStatus;
  statusReason?: string | null;
  reviewRequired: boolean;
  total: number;
  createdUtc: string;
  updatedUtc: string;
  lines: OrderLine[];
}

export interface Me {
  id: string;
  name: string;
  isAdmin: boolean;
}

export interface UploadTarget {
  uploadUrl: string;
  method: string;
  headers: Record<string, string>;
  blobName: string;
  expiresUtc: string;
}

export interface PlatformInfo {
  version: string;
  environment: string;
  framework: string;
  hosting: { model: string; region?: string | null; instance: string; detail?: string | null };
  authMode: string;
  providers: { catalog: string; orders: string; messaging: string; telemetry: string; images: string };
  integrations: Record<string, boolean>;
  features: Record<string, boolean>;
  bannerMessage?: string | null;
}

export interface HealthReport {
  status: string;
  dependencies: Record<string, string>;
}

export interface TelemetryEvent {
  type: string;
  productId?: string;
  sessionId: string;
  timestamp: string;
}
