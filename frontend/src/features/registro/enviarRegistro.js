// Envío del asistente (Tarea 19 del plan): PRIMERO abrirOrden (la
// orden existe antes de subir un solo archivo), DESPUÉS cada adjunto.
// Los adjuntos que fallen quedan en `pendientes` para reintentarlos; el
// borrador se limpia SOLO cuando la orden se completó (o el reintento
// terminó) — si la sesión venció, el borrador queda a salvo (spec §7.2).
import { subirAdjunto, abrirOrden } from "./registroService.js";
import { limpiarBorrador } from "./borrador.js";

export async function enviarRegistro(estado, archivos, opciones = {}) {
  const { userId, ordenIdExistente, pendientesIniciales = [] } = opciones;

  // Reintento de adjuntos: la orden ya existe, no se vuelve a crear.
  if (ordenIdExistente) {
    const pendientes = [];
    for (const a of pendientesIniciales) {
      const subida = await subirAdjunto(ordenIdExistente, a.archivo, {
        tipo: a.tipo,
        etiqueta: a.etiqueta,
      });
      if (!subida.ok) pendientes.push(a);
    }
    if (pendientes.length === 0 && userId) limpiarBorrador(userId);
    return { ok: true, registro: { orden_id: ordenIdExistente }, pendientes };
  }

  const r = await abrirOrden({
    serial: estado.serial,
    productoId: estado.productoId,
    clienteId: estado.clienteId,
    falla: estado.falla,
    accesorios: estado.accesorios,
    tipoSoporte: estado.tipoSoporte,
    numeroSoporte: estado.numeroSoporte,
    fechaEmision: estado.fechaEmision,
    plazoDias: estado.plazoDias,
    vendedor: estado.vendedor,
    checklist: estado.checklist,
    observaciones: estado.observaciones,
    claveEnvio: estado.claveEnvio,
  });
  if (!r.ok) {
    // El borrador NO se limpia: el técnico restaura y reenvía al volver a entrar.
    return { ok: false, codigo: r.codigo, mensaje: r.mensaje, pendientes: archivos };
  }
  const registro = r.datos;
  const pendientes = [];
  for (const a of archivos ?? []) {
    const subida = await subirAdjunto(registro.orden_id, a.archivo, {
      tipo: a.tipo,
      etiqueta: a.etiqueta,
    });
    if (!subida.ok) pendientes.push(a);
  }
  if (pendientes.length === 0 && userId) limpiarBorrador(userId);
  return { ok: true, registro, pendientes };
}