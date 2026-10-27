import { useEffect, useState, type FormEvent } from 'react';
import { api } from '../api';
import { errorMessage } from '../format';
import type { Product } from '../types';

const emptyForm = { id: '', name: '', category: '', description: '', price: '', stock: '' };

export function Admin({ onMessage }: { onMessage: (message: string) => void }) {
  const [products, setProducts] = useState<Product[]>([]);
  const [form, setForm] = useState(emptyForm);
  const [imageProduct, setImageProduct] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [chaosResult, setChaosResult] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const reload = () =>
    api
      .products()
      .then((list) => {
        setProducts(list);
        setImageProduct((current) => current || list[0]?.id || '');
      })
      .catch((e) => onMessage(errorMessage(e)));

  useEffect(() => {
    void reload();
  }, []);

  const edit = (product: Product) =>
    setForm({
      id: product.id,
      name: product.name,
      category: product.category,
      description: product.description,
      price: String(product.price),
      stock: String(product.stock),
    });

  const save = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      const saved = await api.saveProduct({
        id: form.id || undefined,
        name: form.name,
        category: form.category,
        description: form.description,
        price: Number(form.price),
        stock: Number(form.stock),
      });
      onMessage(`Saved ${saved.name}. (Changing an existing product's category is refused: it is the Cosmos DB partition key.)`);
      setForm(emptyForm);
      await reload();
    } catch (err) {
      onMessage(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  const upload = async () => {
    if (!file || !imageProduct) return;
    setBusy(true);
    try {
      const target = await api.uploadImage(imageProduct, file);
      const direct = !target.uploadUrl.startsWith('/');
      onMessage(
        direct
          ? `Uploaded straight to Blob Storage with a SAS. Event Grid → Function will attach it in a few seconds; refresh the shop.`
          : `Uploaded to the local API stand-in and attached immediately.`,
      );
      setFile(null);
    } catch (err) {
      onMessage(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  const chaos = async (kind: 'exception' | 'latency' | 'dependency') => {
    setChaosResult(`Calling ${kind}…`);
    const started = performance.now();
    try {
      await api.chaos(kind);
      setChaosResult(`${kind}: OK after ${Math.round(performance.now() - started)} ms`);
    } catch (err) {
      setChaosResult(`${kind}: ${errorMessage(err)}`);
    }
  };

  const field = (key: keyof typeof emptyForm) => ({
    value: form[key],
    onChange: (e: { target: { value: string } }) => setForm({ ...form, [key]: e.target.value }),
  });

  return (
    <div className="admin">
      <section className="panel">
        <h2>Product</h2>
        <form onSubmit={(e) => void save(e)} className="form">
          <label>
            Id <span className="muted small">(blank = from name)</span>
            <input {...field('id')} placeholder="contoso-ultrabook-14" />
          </label>
          <label>
            Name
            <input {...field('name')} required />
          </label>
          <label>
            Category
            <input {...field('category')} required placeholder="laptops" />
          </label>
          <div className="row">
            <label>
              Price
              <input {...field('price')} type="number" min="0.01" step="0.01" required />
            </label>
            <label>
              Stock
              <input {...field('stock')} type="number" min="0" step="1" required />
            </label>
          </div>
          <label>
            Description
            <textarea {...field('description')} rows={2} />
          </label>
          <div className="row">
            <button className="primary" disabled={busy}>
              Save
            </button>
            <button type="button" className="ghost" onClick={() => setForm(emptyForm)}>
              Clear
            </button>
          </div>
        </form>
        <ul className="product-picker">
          {products.map((p) => (
            <li key={p.id}>
              <button className="link" onClick={() => edit(p)}>
                {p.name}
              </button>
              <span className="muted small"> {p.category}</span>
            </li>
          ))}
        </ul>
      </section>

      <section className="panel">
        <h2>Product image</h2>
        <p className="muted small">
          Valet-key pattern: the API returns a short-lived, write-only SAS and the browser uploads directly to Blob Storage.
          BlobCreated → Event Grid → Function validates the file and attaches it to the product.
        </p>
        <div className="form">
          <label>
            Product
            <select value={imageProduct} onChange={(e) => setImageProduct(e.target.value)}>
              {products.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Image (PNG, JPEG, WebP, GIF · max 5 MB)
            <input type="file" accept="image/png,image/jpeg,image/webp,image/gif" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
          </label>
          <button className="primary" disabled={!file || busy} onClick={() => void upload()}>
            Upload
          </button>
        </div>
      </section>

      <section className="panel">
        <h2>Chaos</h2>
        <p className="muted small">Generate signals to find in Application Insights (Failures, Performance, Application Map).</p>
        <div className="row wrap">
          <button className="ghost" onClick={() => void chaos('exception')}>
            Throw exception
          </button>
          <button className="ghost" onClick={() => void chaos('latency')}>
            3 s latency
          </button>
          <button className="ghost" onClick={() => void chaos('dependency')}>
            Failing dependency
          </button>
        </div>
        {chaosResult && <p className="small">{chaosResult}</p>}
      </section>
    </div>
  );
}
