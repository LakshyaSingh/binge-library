// Screenshot recognition with Google's Gemini API (free tier works).
const PROMPT = `You are looking at a screenshot taken while browsing a streaming service (e.g. Netflix, Prime Video, Apple TV, Hulu, Max, Disney+).
Identify the ONE movie or TV show that is the main focus of the screenshot (the title page, hero banner, or highlighted/selected tile). The title is often shown as a stylized logo — read it carefully.
Also identify which streaming service UI this is, from logos, branding, layout and colors (Netflix: black UI, red N; Prime Video: dark blue, "prime" / "Included with Prime"; Apple TV: "tv+" / Apple logo, glassy UI).
Respond with JSON only:
{"title": string|null, "type": "movie"|"tv"|null, "year": number|null, "platform": "Netflix"|"Prime Video"|"Apple TV"|"Hulu"|"Max"|"Disney+"|"Peacock"|"Paramount+"|null, "alternates": string[], "confidence": number}
"alternates" lists other titles clearly visible in the screenshot (max 4). If this is not a streaming screenshot, return title null.`;

export const hasGemini = () => Boolean(process.env.GEMINI_API_KEY);

const SCHEMA = {
  type: 'object',
  properties: {
    title: { type: 'string', nullable: true },
    type: { type: 'string', enum: ['movie', 'tv'], nullable: true },
    year: { type: 'integer', nullable: true },
    platform: { type: 'string', nullable: true },
    alternates: { type: 'array', items: { type: 'string' } },
    confidence: { type: 'number' },
  },
  required: ['title', 'platform'],
};

// Fastest reliable model first; fall back when a model is busy, retired, rate-limited or hangs.
const DEFAULT_MODELS = ['gemini-3.6-flash', 'gemini-3.8-flash', 'gemini-3.5-flash-lite'];
// Models that recently hung or reported overload are skipped for 10 minutes.
const cooldown = new Map();
const cooling = (m) => (cooldown.get(m) || 0) > Date.now();
const cool = (m) => cooldown.set(m, Date.now() + 10 * 60_000);

async function call(model, buffer, mimeType) {
  return fetch('https://generativelanguage.googleapis.com/v1beta/interactions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY },
    body: JSON.stringify({
      model,
      input: [{ type: 'image', data: buffer.toString('base64'), mime_type: mimeType }, { type: 'text', text: PROMPT }],
      response_format: SCHEMA,
    }),
    signal: AbortSignal.timeout(20_000),
  });
}

function outputText(data) {
  return (data.steps || [])
    .filter((s) => s.type === 'model_output')
    .flatMap((s) => s.content || [])
    .map((c) => c.text || '')
    .join('');
}

export async function recognizeWithGemini(buffer, mimeType) {
  const all = [...new Set([process.env.GEMINI_MODEL, ...DEFAULT_MODELS].filter(Boolean))];
  const models = all.filter((m) => !cooling(m)).length ? all.filter((m) => !cooling(m)) : all;
  let lastErr;
  for (const model of models) {
    let res;
    try { res = await call(model, buffer, mimeType); }
    catch (e) { cool(model); lastErr = Object.assign(new Error(`Gemini timed out (${model})`), { status: 504 }); continue; }
    if (res.ok) {
      const text = outputText(await res.json());
      const json = JSON.parse(text.replace(/^```(json)?|```$/g, '').trim());
      return { ...json, model };
    }
    const body = await res.text();
    lastErr = Object.assign(new Error(`Gemini ${res.status}: ${body.slice(0, 200)}`), { status: res.status });
    if (res.status === 401 || res.status === 403 || res.status === 400) break; // bad key or request: other models won't help
    if ([404, 429, 500, 503].includes(res.status)) cool(model);
  }
  throw lastErr;
}
