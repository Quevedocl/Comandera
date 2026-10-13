// Revisión estática sin dependencias:  node tests/check.js
//  1) el JavaScript de cada HTML tiene sintaxis válida (y sw.js, config.js)
//  2) todo  $('#id')  /  getElementById  que usa el código existe en el HTML (o se crea desde el JS)
//  3) los archivos que el HTML referencia (config.js, íconos, manifest) existen
//  4) no hay claves secretas (service_role / sk-ant) en el repositorio
const fs = require('fs'), path = require('path'), vm = require('vm');
const root = path.join(__dirname, '..');
let bad = 0; const fail = m => { bad++; console.error('✗ ' + m); }; const ok = m => console.log('✓ ' + m);

for (const f of ['index.html', 'carta.html']) {
  const html = fs.readFileSync(path.join(root, f), 'utf8');
  const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  scripts.forEach((code, i) => { try { new vm.Script(code, { filename: f + '#script' + i }); } catch (e) { fail(`${f}: error de sintaxis en <script> #${i}: ${e.message}`); } });
  const js = scripts.join('\n'), ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
  for (const m of js.matchAll(/\$\$?\(\s*'#([A-Za-z][\w-]*)'/g)) if (!ids.has(m[1]) && !js.includes(`id="${m[1]}"`) && !js.includes(`id=\\"${m[1]}\\"`) && !js.includes(`.id = '${m[1]}'`)) fail(`${f}: el código usa #${m[1]} pero no existe en el HTML`);
  const markup = html.replace(/<script(?![^>]*\bsrc=)[^>]*>[\s\S]*?<\/script>/g, '');   // solo el HTML, no las plantillas dentro del JS
  for (const m of markup.matchAll(/(?:src|href)="([^"#?]+)"/g)) { const u = m[1]; if (/^(https?:|data:|mailto:|tel:|\/\/|javascript:)/.test(u) || u.includes('${')) continue; if (!fs.existsSync(path.join(root, u))) fail(`${f}: referencia a un archivo que no existe: ${u}`); }
  if (!bad) ok(`${f}: sintaxis, elementos y archivos referenciados`);
}
for (const f of ['sw.js', 'config.js']) { try { new vm.Script(fs.readFileSync(path.join(root, f), 'utf8'), { filename: f }); ok(f + ': sintaxis'); } catch (e) { fail(f + ': ' + e.message); } }
try { const m = JSON.parse(fs.readFileSync(path.join(root, 'manifest.webmanifest'), 'utf8')); m.icons.forEach(i => { if (!fs.existsSync(path.join(root, i.src.split('?')[0]))) fail('manifest: falta ' + i.src); }); ok('manifest.webmanifest'); } catch (e) { fail('manifest: ' + e.message); }

const walk = d => fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.name === '.git' || e.name === 'node_modules' ? [] : e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
for (const f of walk(root)) { if (/\.(png|ico)$/.test(f)) continue; const t = fs.readFileSync(f, 'utf8'); if (/service_role\s*['"]?\s*[:=]\s*['"]eyJ|sk-ant-[A-Za-z0-9_-]{20,}/.test(t)) fail('posible clave secreta en ' + path.relative(root, f)); }
if (!bad) ok('sin claves secretas');
process.exit(bad ? 1 : 0);
