// Envío del asistente (Tarea 19 del plan): PRIMERO registrarIngreso (el
// registro existe antes de subir un solo archivo), DESPUÉS cada adjunto.
// Los adjuntos que fallen quedan en `pendientes` para reintentarlos; el
// borrador se limpia SOLO cuando el registro se completó (o el reintento
// terminó) — si la sesión venció, el borrador queda a salvo (spec §7.2).
import { subirAdjunto, registrarIngreso } from "./registroService.js";
import { limpiarBorrador } from "./borrador.js";

export async function enviarRegistro(estado, archivos, opciones = {}) {
  const { userId, registroIdExistente, pendientesIniciales = [] } = opciones;

  // Reintento de adjuntos: el registro ya existe, no se vuelve a crear.
  if (registroIdExistente) {
    const pendientes = [];
    for (const a of pendientesIniciales) {
      const subida = await subirAdjunto(registroIdExistente, a.archivo, {
        tipo: a.tipo,
        etiqueta: a.etiqueta,
      });
      if (!subida.ok) pendientes.push(a);
    }
    if (pendientes.length === 0 && userId) limpiarBorrador(userId);
    return { ok: true, registro: { registro_id: registroIdExistente }, pendientes };
  }

  const r = await registrarIngreso({
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
    const subida = await subirAdjunto(registro.registro_id, a.archivo, {
      tipo: a.tipo,
      etiqueta: a.etiqueta,
    });
    if (!subida.ok) pendientes.push(a);
  }
  if (pendientes.length === 0 && userId) limpiarBorrador(userId);
  return { ok: true, registro, pendientes };
}