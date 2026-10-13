# Mejoras implementadas — orden de instalación

1. **Supabase > SQL Editor**: ejecuta `supabase/migracion-mejoras.sql` (es repetible). Hazlo ANTES de subir los HTML.
2. **Supabase > Authentication > Emails > Templates > Confirm signup**: pega `supabase/email-template-confirmar-registro.html`
   (debe contener `{{ .Token }}`; sin eso llegaría el link en vez del código).
   Opcional: Authentication > Providers > Email → largo y vencimiento del código (OTP).
3. Sube `index.html` y `carta.html`.

## Web (index.html)
- **Ingresos**: pestaña nueva (ventas, cobrado, por cobrar, pedidos, ticket promedio, agregados, ventas por hora, más vendidos, selector de día) + "Ventas hoy" en Pedidos. Los pedidos cancelados no cuentan.
- **Agregados**: pestaña nueva. Se crean por producto o por categoría, con precio; se activan/desactivan y editan inline.
- **Producto**: ahora tiene descripción y botón de editar (lápiz).
- **Configuración**: propina sugerida (0 = sin sugerencia, 10% por defecto).
- **Registro con código**: ya no usa link; verifica con código, con reenvío (60 s). Si alguien se registró y nunca verificó, al ingresar se le envía un código nuevo.
- **Animaciones**: contadores animados, barras, esqueleto de carga, ondas en botones, confeti al cobrar mesa, progreso en tickets, avisos de pedido modificado/cancelado (con sonido), fondo animado en el login. Respeta "reducir movimiento".

## Móvil (carta.html)
- **Cómo va mi pedido**: franja con estado en vivo (recibido → preparando → listo), aviso y vibración al cambiar.
- **Cancelar / modificar**: solo mientras está "Recibido". Modificar lo devuelve al carrito; cocina ve la marca "Modificado".
- **Cuenta dividida o compartida**: toda la mesa ve la misma cuenta; se puede dividir en partes iguales, solo lo mío o por producto. El botón avisa al mesero con el monto en la nota.
- **Vista previa**: toca un plato → foto grande, descripción, agregados y nota.
- **Propina sugerida**: en la cuenta (0%, sugerida, +5, +10, otro %).

## Cobro parcial (mesa abierta)
1. **Supabase > SQL Editor**: ejecuta `supabase/migracion-cobro-parcial.sql` ANTES de subir los HTML.
2. En el panel, la llamada "Quiere pagar" tiene dos botones: **Cobrar y cerrar mesa** (como antes) y **Cobrar y dejar abierta**.
   El segundo marca como pagado lo pedido hasta ese aviso; si el cliente sigue pidiendo, su próxima cuenta solo suma lo nuevo y muestra "Ya pagado antes".
3. Los tickets cobrados muestran la etiqueta **Pagado**; en Ingresos, "Cobrado" incluye lo pagado aunque la mesa siga abierta.
