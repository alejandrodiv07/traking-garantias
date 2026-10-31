# Pendientes — Track Garantía

Corte: 2026-10-30 · Rama de trabajo: `feat/fase-2b` (sale de `feat/fase-2a`)

Tres listas: lo que debes hacer tú, lo que me falta a mí (backend/SQL, docs) y lo que le falta a la otra sesión (frontend).

---

## 1. Para ti (despliegue y pruebas reales)

Es lo que más riesgo cubre. Ninguna de estas tareas la puedo hacer desde el entorno de desarrollo.

### 1.1 Comprobar la base remota
- [ ] En el SQL Editor de Supabase: `select version from supabase_migrations.schema_migrations order by version;` y confirmar que llega hasta `20261030000022`.
- [ ] Probar `select * from public.buscar_equipo(p_serial => 'X');` con un usuario real (no con el rol de servicio).
- [ ] Cuando se apruebe la 2b: aplicar `20261030000023_ventas_facturas.sql` y comprobar que `schema_migrations` la incluye.

### 1.2 Inicio de sesión con segundo factor (D11)
- [ ] Verificar el dominio de envío en Resend.
- [ ] Revertir el hotfix de `mfa-enviar-codigo` (hoy manda siempre al mismo destinatario) y redesplegarla.
- [ ] Probar el login con dos usuarios distintos: cada uno debe recibir su propio código.
- Referencia: `ESTADO_DEL_PROYECTO.md`, deuda D11, y la nota de memoria "MFA login 502".

### 1.3 Limpieza de huérfanos (C2/C3)
- [ ] Definir `app.proyecto_ref` y `app.limpieza_secret` en la base.
- [ ] Desplegar las tres Edge Functions.
- [ ] Probar `limpiar-huerfanos` con `?simular=1` (no borra, solo informa).

### 1.4 Recorrido real en el navegador (por rol)
Con el sitio desplegado, un usuario por rol:
- [ ] **RECEPCION:** registrar garantía (plazo 7 o 15); un plazo distinto debe rechazarse.
- [ ] **TECNICO:** consultar por serial, cédula, factura y orden; abrir orden; subir foto y documento de recepción; avanzar estados; registrar presupuesto si es de pago.
- [ ] **JEFE_SERVICIO:** asignar técnico; rechazar una orden con motivo (sin motivo debe fallar); entregarla; confirmar y desestimar una garantía `TALLER`.
- [ ] **ADMIN:** fijar un plazo distinto de 7/15.
- [ ] Un usuario sin perfil o con sesión revocada no ve datos.
- [ ] Móvil: el detalle de la orden y el formulario de abrir orden se usan bien con el teclado abierto.

### 1.5 Decisiones tuyas
- [ ] ¿Los dos PDF y `diseno.md` van al repositorio? Hoy están sin trackear (los PDF probablemente no deberían entrar).
- [ ] `docs/CAMBIOS_FASE_2A.md` y `docs/diseno-ui/`: sin trackear; decidir si se comprometen.
- [ ] Docker Desktop dejó de responder (error 500 al ping). Reiniciarlo (icono de Docker, o `wsl --shutdown` y abrirlo de nuevo). Hay muchos contenedores `postgres:17` huérfanos de pruebas anteriores: conviene `docker rm -f $(docker ps -aq --filter ancestor=postgres:17)`.

---

## 2. Me faltan a mí (SQL, scripts y documentación)

### 2.1 Fase 2b — tarea 1 (migración 0023): escrita, sin verificar
Archivos ya creados en `feat/fase-2b`, **sin comprometer**:
- `supabase/migrations/20261030000023_ventas_facturas.sql`
- `supabase/tests/29_ventas_importar.sql` (22 aserciones)

Para cerrarla:
- [ ] Con Docker arriba: `bash supabase/tests/run.sh supabase/tests/29_ventas_importar.sql` y arreglar lo que falle.
- [ ] Correr la suite completa por tandas (la máquina anda justa de memoria): `bash supabase/tests/run.sh` con grupos de archivos.
- [ ] Revisar que `verificar-migraciones.sh` siga en OK (23 migraciones).
- [ ] Comprometer migración y prueba juntas.

Decisión ya tomada: la confirmación automática exige **factura + serial + documento + fecha de emisión** iguales. Si la fecha no debe contar, se quita una línea en `verificacion_venta`.

### 2.2 Fase 2b — tareas siguientes
Diseño completo: `docs/superpowers/specs/2026-10-30-fase-2b-facturas-ventas-csv-design.md`.
- [ ] **T2:** actualizar `scripts/e2e-registro.sh` (importar ventas y ver que una garantía `TALLER` pasa a EN_GARANTIA sola).
- [ ] **T3:** documentar el contrato para el frontend: `importar_ventas(archivo, filas jsonb)` devuelve `lote_id, nuevas, actualizadas, con_error, confirmadas, errores[{fila,campo,mensaje}]`; `v_garantias` gana `verificacion` y `compra_confirmada_via`.
- [ ] **T5:** README y `ESTADO_DEL_PROYECTO.md`: cadena 0013–0023, cifras de pruebas, rutas nuevas.

### 2.3 Deuda y mantenimiento
- [ ] Cifras de pruebas en README/ESTADO al cerrar la 2b (hoy: 436 SQL + 312 vitest, sin contar la prueba 29).
- [ ] Documento de fase 2c (enlace público de seguimiento y alertas por correo) cuando se priorice.

---

## 3. Le faltan a la otra sesión (frontend)

### 3.1 Fase 2b — pantalla de importación
Depende de que la tarea 1 esté verificada y comprometida (el contrato de la RPC es el de arriba).
- [ ] `ventasService.js` con `importarVentas(archivo, filas)`.
- [ ] Parser de CSV en el navegador, sin dependencias nuevas: delimitador `;` o `,`, UTF-8 con o sin BOM, comillas, líneas vacías. Columnas: `numero_factura, fecha_emision, tipo_documento, numero_documento, nombre_cliente, serial, modelo` (y `vendedor` opcional). Pruebas primero.
- [ ] Ruta `/ventas/importar`, solo ADMIN y JEFE_SERVICIO:
  1. elegir archivo → vista previa con las filas inválidas marcadas;
  2. «Importar N filas válidas» → resumen (nuevas, actualizadas, con error, garantías confirmadas);
  3. descargar las filas con error como CSV.
- [ ] Insignias en Garantías y Consulta según `verificacion`: *Respaldada por Ventas*, *No coincide / Revisión requerida*, *Sin venta*.
- [ ] Enlace a la pantalla desde Garantías (solo Jefatura).
- [ ] Límite de 5000 filas por envío: partir el archivo en bloques si hace falta.

### 3.2 Fase 2a — detalles pendientes del detalle de orden
- [ ] Recorrido manual de `OrdenDetalle` con cada rol (qué botones ve cada uno).
- [ ] Revisar el flujo de subida de foto y documento contra el Storage real (en las pruebas se simula).
- [ ] Limpiar los avisos de lint antiguos (`adjuntos-resumen.test.jsx`, `AuthContext.jsx`).

### 3.3 Pantallas sin backend (fuera de la 2b, requieren diseño antes)
- [ ] **Entregas** (maqueta 05): acta/constancia de retiro.
- [ ] **Inventario** (06), **Reportes** (07), **Clientes** (08) y **Notificaciones**.
- Hoy la entrega se hace desde el detalle de la orden con `cambiar_estado`.

---

## 4. Orden sugerido

1. Docker arriba → yo verifico y comprometo la 0023.
2. Tú: puntos 1.1 a 1.3 (base remota, Resend, limpieza).
3. La otra sesión: pantalla de importación (3.1).
4. Tú: recorrido real por rol (1.4).
5. Yo: e2e, README y ESTADO de la 2b.
6. Después: 2c (enlace público y alertas) y Entregas.
