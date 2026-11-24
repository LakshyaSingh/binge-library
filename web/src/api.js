async function req(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: opts.body && !(opts.body instanceof FormData) ? { 'content-type': 'application/json', ...opts.headers } : opts.headers,
    body: opts.body && !(opts.body instanceof FormData) ? JSON.stringify(opts.body) : opts.body,
  });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

export const api = {
  status: () => req('/api/status'),
  saveSettings: (body) => req('/api/settings', { method: 'POST', body }),
  search: (q) => req(`/api/search?q=${encodeURIComponent(q)}`),
  details: (type, id) => req(`/api/title/${type}/${id}`),
  library: () => req('/api/library'),
  add: (body) => req('/api/library', { method: 'POST', body }),
  update: (id, body) => req(`/api/library/${id}`, { method: 'PATCH', body }),
  refresh: (id) => req(`/api/library/${id}/refresh`, { method: 'POST' }),
  remove: (id) => req(`/api/library/${id}`, { method: 'DELETE' }),
  recognize: (files) => {
    const fd = new FormData();
    for (const f of files) fd.append('images', f);
    return req('/api/recognize', { method: 'POST', body: fd });
  },
};
