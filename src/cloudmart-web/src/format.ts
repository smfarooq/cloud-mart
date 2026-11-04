export const errorMessage = (error: unknown) => (error instanceof Error ? error.message : String(error));

export const money = (amount: number) => amount.toLocaleString(undefined, { style: 'currency', currency: 'USD' });

export const bytes = (count: number) => {
  if (count < 1024) return `${count} B`;
  if (count < 1024 * 1024) return `${(count / 1024).toFixed(1)} KB`;
  return `${(count / 1024 / 1024).toFixed(1)} MB`;
};

export const timeAgo = (iso: string) => {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
  return new Date(iso).toLocaleString();
};
