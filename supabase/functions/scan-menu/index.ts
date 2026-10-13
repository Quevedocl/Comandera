// Deploy: supabase functions deploy scan-menu   ·   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const SYSTEM = 'Eres un lector de cartas de restaurante. Responde SOLO con JSON: {"items":[{"name":string,"category":string,"price":integer}]}. Usa como category el título de la sección donde aparece el plato. price es un entero en pesos chilenos sin símbolos ni puntos (si falta, 0). No inventes platos ni precios.';
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const out = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'content-type': 'application/json' } });
  try {
    const { images } = await req.json();
    if (!Array.isArray(images) || !images.length || images.length > 6) return out({ error: 'bad input' }, 400);
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': Deno.env.get('ANTHROPIC_API_KEY')!, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-5-5', max_tokens: 8000, system: SYSTEM, messages: [{ role: 'user', content: [
        ...images.map((data: string) => ({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data } })),
        { type: 'text', text: 'Extrae todos los productos de esta carta.' }] }] }),
    });
    const j = await r.json();
    const txt = j.content?.find((c: { type: string }) => c.type === 'text')?.text ?? '{}';
    return out({ items: JSON.parse(txt.replace(/```json|```/g, '').trim()).items ?? [] });
  } catch (e) { return out({ error: String(e) }, 500); }
});
