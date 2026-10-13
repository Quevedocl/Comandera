# Fogón

Pedidos desde la mesa por QR para restaurantes, vendido como **suscripción mensual**. El cliente escanea el QR, ve la carta y pide; el restaurante ve los pedidos en vivo, llama al mesero y administra su carta. **No procesa pagos ni boletas: el cobro lo hace el mesero** (la app solo deja registrado qué mesa ya pagó).

- `index.html` — panel del restaurante (pedidos, carta, agregados, promos, mesas, ingresos, llamadas, configuración) y panel de administrador de la plataforma.
- `carta.html` — carta que ve el cliente (`carta.html?r=<slug>&t=<id de mesa>`).
- `config.js` — URL y clave pública de Supabase (único lugar donde se cambian).
- `supabase/` — base de datos (`schema.sql`, migraciones) y plantillas de correo.
- `manifest.webmanifest`, `sw.js`, `icons/` — el panel se puede instalar como app y abre aunque se corte el internet (los pedidos igual requieren conexión).

## Instalación desde cero

1. Crea un proyecto en [Supabase](https://supabase.com).
2. **SQL Editor**: pega y ejecuta `supabase/schema.sql` (una sola vez, proyecto vacío).
3. **Authentication > Sign In / Providers > Email**: activa *Confirm email* (el registro y la recuperación usan un código de 6 dígitos).
4. **Authentication > Emails > Templates**: pega `supabase/email-template-confirmar-registro.html` en *Confirm signup* y `supabase/email-template-recuperar-contrasena.html` en *Reset Password*. Ambas deben contener `{{ .Token }}`.
5. Edita `config.js` con tu **Project URL** y la clave **anon / publishable** (Project Settings > API). Nunca pongas la `service_role`.
6. Sube todo (excepto `supabase/`, `tests/`, `.github/`) a un hosting estático con HTTPS (Netlify, Vercel, GitHub Pages, Cloudflare Pages…). Los archivos deben quedar en la misma carpeta.
7. Abre `index.html`, crea tu cuenta y hazte administrador (SQL Editor): 
   `insert into admins (email) values ('tu-correo@ejemplo.com') on conflict do nothing;`

Si usas un dominio propio de Supabase (no `*.supabase.co`), agrégalo en `connect-src` de la etiqueta *Content-Security-Policy* de ambos HTML.

## Actualizar un proyecto que ya funciona

Ejecuta en **SQL Editor**, en este orden, solo las que te falten (todas son repetibles), **antes** de subir los HTML nuevos:

1. `migracion-sesion-mesa.sql`
2. `migracion-liberar-mesa.sql`
3. `migracion-admin-y-marca.sql` (agrega tu correo de administrador como indica el comentario)
4. `migracion-mejoras.sql`
5. `migracion-cobro-parcial.sql`
6. `migracion-local-abierto.sql`
7. **`migracion-7-seguridad.sql`** — precios calculados en el servidor, tope anti-spam, índices, fotos, historial y el permiso que faltaba para el botón *Abierto/Cerrado*.

## Seguridad: qué garantiza la base de datos

- El **total y los precios** de cada pedido los calcula el servidor con los precios vigentes (incluye agregados y promociones); lo que mande el celular se ignora. Productos agotados, cantidades fuera de 1–20 o agregados que no corresponden se rechazan.
- Máximo 40 pedidos por mesa cada 10 minutos. Un pedido nuevo nunca nace "pagado".
- Cada dueño solo ve y edita lo de su restaurante. Solo el administrador (tabla `admins`) puede suspender locales.
- Fotos: solo imagen, máx. 5 MB, y cada dueño escribe/borra solo en su carpeta. El panel las reduce a WebP antes de subirlas.

## Para operar el negocio

- **Dar de alta un restaurante**: se registra solo en `index.html`. **Suspender por falta de pago**: pestaña *Admin* > *Suspender* (la carta deja de recibir pedidos).
- Hoy cualquiera puede registrarse; si quieres vender solo por invitación, desactiva *Enable sign ups* en Supabase y crea las cuentas tú.
- Impresión de comanda (botón de impresora en cada ticket, formato 80 mm) y exportación de pedidos del día a CSV (pestaña *Ingresos*).

## Pruebas

- `node tests/check.js` — sintaxis de los HTML/JS, elementos y archivos referenciados, y que no haya claves secretas (también corre en GitHub Actions).
- `supabase/tests/` — pruebas de seguridad del SQL para una base PostgreSQL de prueba (ver cabecera del archivo).
